#!/bin/sh
# Isolated real ucode worker with fake GitHub and a harmless fake installer.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BOX=/tmp/outbound-monitor-check/update-integration
mkdir -p "$BOX/bin"
chmod 700 "$BOX"
cp "$ROOT/outbound-monitor/files/usr/share/outbound-monitor/update-core.uc" "$BOX/update-core.uc"
sed -e "s|const DIR = .*|const DIR = '$BOX';|" \
 -e "s|const VERSION = .*|const VERSION = '$BOX/version';|" \
 -e "s|const INSTALLER = .*|const INSTALLER = '$BOX/installer';|" \
 "$ROOT/outbound-monitor/files/usr/share/outbound-monitor/update.uc" > "$BOX/update.uc"
echo 0.1.0 > "$BOX/version"
rm -f "$BOX/update.json"
ucode -e '
import {writefile} from "fs";
let names=["outbound-monitor.apk","luci-app-outbound-monitor.apk","luci-i18n-outbound-monitor-ru.apk","outbound-monitor.ipk","luci-app-outbound-monitor.ipk","luci-i18n-outbound-monitor-ru.ipk","SHA256SUMS"];
let r={tag_name:"2026-9-23-1",draft:false,prerelease:false,assets:map(names,(name)=>({name,browser_download_url:"https://github.com/romanilyin/outbound-monitor-openwrt/releases/download/2026-9-23-1/"+name}))};
writefile(ARGV[0],sprintf("%J",r));' "$BOX/release.json"
cat > "$BOX/bin/curl" <<'EOF'
#!/bin/sh
base=/tmp/outbound-monitor-check/update-integration
if [ -f "$base/network-failed" ]; then exit 22; fi
cat "$base/release.json"
EOF
cat > "$BOX/installer" <<'EOF'
#!/bin/sh
set -eu
base=/tmp/outbound-monitor-check/update-integration
test "$OUTBOUND_MONITOR_RELEASE" = 2026-9-23-1
echo "$OUTBOUND_MONITOR_RELEASE" > "$base/version"
echo 'Fake package installed; no router package changes'
EOF
chmod 755 "$BOX/bin/curl" "$BOX/installer"
export PATH="$BOX/bin:$PATH"
rm -f "$BOX/network-failed"
ucode "$BOX/update.uc" check
ucode "$BOX/update.uc" status > "$BOX/status.json"
ucode -e 'import {readfile} from "fs"; let s=json(readfile(ARGV[0])); if(!s.available||s.running||s.stage!="idle"||s.latest!="2026-9-23-1") die("check failed\n");' "$BOX/status.json"
ucode "$BOX/update.uc" install
ucode "$BOX/update.uc" status > "$BOX/status.json"
ucode -e 'import {readfile} from "fs"; let s=json(readfile(ARGV[0])); if(s.available||s.running||s.stage!="done"||s.current!="2026-9-23-1") die("install failed\n");' "$BOX/status.json"
ucode "$BOX/update.uc" install
ucode "$BOX/update.uc" status > "$BOX/status.json"
ucode -e 'import {readfile} from "fs"; let s=json(readfile(ARGV[0])); if(s.stage!="failed"||!s.error) die("same version was installed\n");' "$BOX/status.json"
touch "$BOX/network-failed"
ucode "$BOX/update.uc" check
ucode "$BOX/update.uc" status > "$BOX/status.json"
ucode -e 'import {readfile} from "fs"; let s=json(readfile(ARGV[0])); if(s.stage!="failed"||!s.error||s.running) die("network failure not reported\n");' "$BOX/status.json"
echo 'PASS updater worker: check, pinned install, same-version refusal, visible network error'
