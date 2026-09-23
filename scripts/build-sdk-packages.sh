#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=${1:-25.12.4}
case "$VERSION" in
 25.12.4) GCC=14.3.0; FORMAT=apk; SHA=28e004c1be4d215d19c1f12a6aa4c8d8f80689549eb707d0ff5a71f16fa8d05f ;;
 24.10.6) GCC=13.3.0; FORMAT=ipk; SHA=9e398ea7efc098e4a986f97efff595e32d08c615fe356bcb3d885d7ad3a39ac0 ;;
 *) echo 'Supported SDKs: 25.12.4, 24.10.6' >&2; exit 1 ;;
esac
WORK=${OUTBOUND_MONITOR_SDK_DIR:-${RUNNER_TEMP:-/tmp}/outbound-monitor-sdk}
NAME="openwrt-sdk-$VERSION-x86-64_gcc-${GCC}_musl.Linux-x86_64"
mkdir -p "$WORK" "$ROOT/dist/$FORMAT"
ARCHIVE="$WORK/$NAME.tar.zst"
if [ ! -f "$ARCHIVE" ]; then
 curl -fL --retry 3 "https://downloads.openwrt.org/releases/$VERSION/targets/x86/64/$NAME.tar.zst" -o "$ARCHIVE"
fi
echo "$SHA  $ARCHIVE" | sha256sum -c -
[ -d "$WORK/$NAME" ] || tar --zstd -xf "$ARCHIVE" -C "$WORK"
cd "$WORK/$NAME"
ln -sfn "$ROOT" package/outbound-monitor-openwrt
./scripts/feeds update -a > "$WORK/feeds-$VERSION.log" 2>&1 || { tail -n 100 "$WORK/feeds-$VERSION.log"; exit 1; }
./scripts/feeds install -a >> "$WORK/feeds-$VERSION.log" 2>&1 || { tail -n 100 "$WORK/feeds-$VERSION.log"; exit 1; }
cat > .config <<'EOF'
CONFIG_HAVE_DOT_CONFIG=y
CONFIG_PACKAGE_outbound-monitor=m
CONFIG_PACKAGE_luci-app-outbound-monitor=m
CONFIG_PACKAGE_luci-i18n-outbound-monitor-ru=m
EOF
make defconfig > "$WORK/build-$VERSION.log" 2>&1
for package in outbound-monitor luci-app-outbound-monitor; do
 if ! make -j2 "package/$package/compile" V=s >> "$WORK/build-$VERSION.log" 2>&1; then
  tail -n 160 "$WORK/build-$VERSION.log"
  exit 1
 fi
done
python3 "$ROOT/scripts/collect-packages.py" "$PWD/bin/packages" "$ROOT/dist/$FORMAT" "$FORMAT"
