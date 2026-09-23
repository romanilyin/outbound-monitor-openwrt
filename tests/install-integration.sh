#!/bin/sh
# Real installer, private filesystem paths and fake downloads/package/services.
# No external requests, live package operations or live service/config changes.
set -eu
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BASE=/tmp/outbound-monitor-check/install
[ "$(id -u)" = 0 ] || { echo 'Installer integration requires root in its isolated sandbox' >&2; exit 1; }
if [ ! -e "$BASE" ] && [ ! -L "$BASE" ]; then mkdir -m 700 "$BASE"; fi
ucode -e 'import * as fs from "fs"; let d=fs.lstat(ARGV[0]); exit(d?.type == "directory" && d.uid == 0 && (d.mode & 0777) == 0700 ? 0 : 1);' "$BASE"
BOX=$(mktemp -d "$BASE/run.XXXXXX")
trap 'rm -rf "$BOX"' EXIT
trap 'exit 1' HUP INT TERM
mkdir -m 700 "$BOX/bin" "$BOX/payload" "$BOX/state"
export INSTALL_TEST_BOX=$BOX
fail() { echo "FAIL installer integration: $*" >&2; cat "$BOX/install.log" 2>/dev/null || true; exit 1; }

# Replace using placeholders first, so the sandbox's own /tmp prefix is never
# matched again. Everything else, including ucode and SHA256 guards, stays real.
sed -e 's|/tmp/outbound-monitor-install\.XXXXXX|__TEST_STAGE__|g' \
    -e 's|/tmp/outbound-monitor|__TEST_STATE__|g' \
    -e 's|/etc/init.d/outbound-monitor|__TEST_MONITOR__|g' \
    -e 's|/etc/init.d/rpcd|__TEST_RPCD__|g' \
    -e 's|/etc/config/outbound-monitor|__TEST_CONFIG__|g' \
    -e 's|/usr/share/outbound-monitor/version|__TEST_VERSION__|g' \
    "$ROOT/install.sh" | \
sed -e "s|__TEST_STAGE__|$BOX/staging.XXXXXX|g" \
    -e "s|__TEST_STATE__|$BOX/state|g" \
    -e "s|__TEST_MONITOR__|$BOX/monitor|g" \
    -e "s|__TEST_RPCD__|$BOX/rpcd|g" \
    -e "s|__TEST_CONFIG__|$BOX/config|g" \
    -e "s|__TEST_VERSION__|$BOX/version|g" > "$BOX/install.sh"
if grep -Eq '/etc/(init.d|config)/|/usr/share/outbound-monitor|/tmp/outbound-monitor([/" .]|$)|__TEST_' "$BOX/install.sh"; then
 fail 'installer contains an unreplaced live path'
fi
sh -n "$BOX/install.sh"
printf '{"tag_name":"2026-9-23-1","draft":false,"prerelease":false}\n' > "$BOX/payload/release.json"
for name in outbound-monitor luci-app-outbound-monitor luci-i18n-outbound-monitor-ru; do
 printf 'Dummy package: %s\n' "$name" > "$BOX/payload/$name.apk"
done
(cd "$BOX/payload" && sha256sum outbound-monitor.apk luci-app-outbound-monitor.apk luci-i18n-outbound-monitor-ru.apk > SHA256SUMS)

cat > "$BOX/bin/curl" <<'EOF'
#!/bin/sh
set -eu
out=; url=
while [ "$#" -gt 0 ]; do
 case "$1" in
  --output) out=$2; shift 2 ;;
  https://*) url=$1; shift ;;
  *) shift ;;
 esac
done
case "$out" in "$INSTALL_TEST_BOX"/staging.*/*) ;; *) exit 80 ;; esac
case "$url" in
 https://api.github.com/repos/romanilyin/outbound-monitor-openwrt/releases/latest|https://api.github.com/repos/romanilyin/outbound-monitor-openwrt/releases/tags/2026-9-23-1) name=release.json ;;
 https://github.com/romanilyin/outbound-monitor-openwrt/releases/download/2026-9-23-1/SHA256SUMS) name=SHA256SUMS ;;
 https://github.com/romanilyin/outbound-monitor-openwrt/releases/download/2026-9-23-1/outbound-monitor.apk) name=outbound-monitor.apk ;;
 https://github.com/romanilyin/outbound-monitor-openwrt/releases/download/2026-9-23-1/luci-app-outbound-monitor.apk) name=luci-app-outbound-monitor.apk ;;
 https://github.com/romanilyin/outbound-monitor-openwrt/releases/download/2026-9-23-1/luci-i18n-outbound-monitor-ru.apk) name=luci-i18n-outbound-monitor-ru.apk ;;
 *) exit 81 ;;
esac
cp "$INSTALL_TEST_BOX/payload/$name" "$out"
if [ "$(cat "$INSTALL_TEST_BOX/mode")" = checksum ] && [ "$name" = luci-app-outbound-monitor.apk ]; then
 printf 'corruption\n' >> "$out"
fi
EOF
cat > "$BOX/bin/apk" <<'EOF'
#!/bin/sh
set -eu
box=$INSTALL_TEST_BOX
case "$1" in
 update) [ "$#" = 1 ]; echo 'apk update' >> "$box/operations" ;;
 add)
  [ "$#" = 5 ] && [ "$2" = --allow-untrusted ]
  shift 2
  for name in outbound-monitor luci-app-outbound-monitor luci-i18n-outbound-monitor-ru; do
   case "$1" in "$box"/staging.*/"$name.apk") ;; *) exit 82 ;; esac
   [ -f "$1" ]; shift
  done
  echo 'apk add' >> "$box/operations"
  echo 2026-9-23-1 > "$box/version"
  echo 'package default replacing user configuration' > "$box/config"
  # Model package post-install hooks changing the monitor's service flags.
  echo 1 > "$box/enabled"; echo 1 > "$box/running"
  ;;
 *) exit 83 ;;
esac
EOF
cat > "$BOX/monitor" <<'EOF'
#!/bin/sh
set -eu
box=$INSTALL_TEST_BOX
case "$1" in
 enabled|running) [ "$(cat "$box/$1")" = 1 ]; exit ;;
 enable) echo 1 > "$box/enabled" ;;
 disable) echo 0 > "$box/enabled" ;;
 restart|start) echo 1 > "$box/running" ;;
 stop) echo 0 > "$box/running" ;;
 *) exit 84 ;;
esac
echo "monitor $1" >> "$box/operations"
EOF
cat > "$BOX/rpcd" <<'EOF'
#!/bin/sh
set -eu
[ "$#" = 1 ] && [ "$1" = reload ]
echo 'rpcd reload' >> "$INSTALL_TEST_BOX/operations"
EOF
chmod 700 "$BOX/bin/curl" "$BOX/bin/apk" "$BOX/monitor" "$BOX/rpcd"
export PATH="$BOX/bin:$PATH"
[ "$(command -v curl)" = "$BOX/bin/curl" ] && [ "$(command -v apk)" = "$BOX/bin/apk" ] || fail 'fake tools not selected'
export OUTBOUND_MONITOR_RELEASE=2026-9-23-1

prepare() {
 echo "$1" > "$BOX/enabled"; echo "$2" > "$BOX/running"
 printf "config monitor 'main'\n option enabled '1'\n option interval '600'\n" > "$BOX/config"
 cp "$BOX/config" "$BOX/expected-config"
 printf '{"keys":[{"id":"history-to-preserve","samples":[[123,1,42]]}]}\n' > "$BOX/state/state.json"
 cp "$BOX/state/state.json" "$BOX/expected-history"
 echo 0.1.0 > "$BOX/version"
 : > "$BOX/operations"
}
verify_preserved() {
 cmp -s "$BOX/config" "$BOX/expected-config" || fail 'existing configuration changed'
 cmp -s "$BOX/state/state.json" "$BOX/expected-history" || fail 'existing history changed'
 [ "$(cat "$BOX/enabled")" = "$1" ] || fail 'enabled flag changed'
 [ "$(cat "$BOX/running")" = "$2" ] || fail 'running flag changed'
 set -- "$BOX"/staging.*
 [ ! -e "$1" ] || fail 'temporary installer workspace remains'
}

prepare 1 1
echo checksum > "$BOX/mode"
if sh "$BOX/install.sh" > "$BOX/install.log" 2>&1; then fail 'bad checksum accepted'; fi
grep -q 'Checksum mismatch for luci-app-outbound-monitor.apk' "$BOX/install.log" || fail 'checksum refusal was not the failure cause'
[ ! -s "$BOX/operations" ] || fail 'checksum failure invoked package manager or changed a service'
[ "$(cat "$BOX/version")" = 0.1.0 ] || fail 'checksum failure installed a version'
verify_preserved 1 1

for flags in 1:1 0:0 1:0 0:1; do
 enabled=${flags%:*}; running=${flags#*:}
 prepare "$enabled" "$running"
 echo success > "$BOX/mode"
 sh "$BOX/install.sh" > "$BOX/install.log" 2>&1 || fail "install failed for enabled=$enabled running=$running"
 [ "$(cat "$BOX/version")" = 2026-9-23-1 ] || fail 'new version not installed'
 [ "$(grep -c '^apk update$' "$BOX/operations")" = 1 ] || fail 'unexpected index refresh count'
 [ "$(grep -c '^apk add$' "$BOX/operations")" = 1 ] || fail 'unexpected package installation count'
 [ "$(grep -c '^rpcd reload$' "$BOX/operations")" = 1 ] || fail 'RPC module not reloaded'
 verify_preserved "$enabled" "$running"
done
echo 'PASS isolated installer: checksum refusal and four enabled/running states, preserved configuration/history'
