#!/bin/sh
# SPDX-License-Identifier: MIT
# Source install for opkg and apk systems; only this plugin's files are copied.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo 'Run as root on OpenWrt' >&2; exit 1; }
for tool in ucode curl flock ubus; do
	command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }
done
ucode -e 'import * as fs from "fs"; import * as uci from "uci"; import * as digest from "digest";'
[ -f /usr/lib/rpcd/ucode.so ] || { echo 'Missing rpcd-mod-ucode' >&2; exit 1; }
[ -d /www/luci-static/resources ] || { echo 'LuCI is required' >&2; exit 1; }
if [ -d "$ROOT/files" ]; then
	BACKEND=$ROOT/files
	LUCI=$ROOT/files
	WEB=$ROOT/files/www
else
	BACKEND=$ROOT/outbound-monitor/files
	LUCI=$ROOT/luci-app-outbound-monitor/root
	WEB=$ROOT/luci-app-outbound-monitor/htdocs
fi
# Validate the complete payload before stopping an existing monitor instance.
for path in usr/bin/outbound-monitor usr/share/outbound-monitor/core.uc usr/share/outbound-monitor/main.uc etc/init.d/outbound-monitor etc/config/outbound-monitor; do
	[ -f "$BACKEND/$path" ] || { echo "Missing payload: $path" >&2; exit 1; }
done
for path in usr/share/rpcd/ucode/outbound-monitor.uc usr/share/rpcd/acl.d/luci-app-outbound-monitor.json usr/share/luci/menu.d/luci-app-outbound-monitor.json; do
	[ -f "$LUCI/$path" ] || { echo "Missing payload: $path" >&2; exit 1; }
done
for path in luci-static/resources/view/outbound-monitor/status.js luci-static/resources/outbound-monitor/style.css; do
	[ -f "$WEB/$path" ] || { echo "Missing payload: $path" >&2; exit 1; }
done
if [ -x /etc/init.d/outbound-monitor ]; then /etc/init.d/outbound-monitor stop; fi
copy_file() {
	source=$1 dest=$2 mode=$3
	mkdir -p "$(dirname "$dest")"
	cp "$source" "$dest"
	chmod "$mode" "$dest"
}
copy_file "$BACKEND/usr/bin/outbound-monitor" /usr/bin/outbound-monitor 755
copy_file "$BACKEND/etc/init.d/outbound-monitor" /etc/init.d/outbound-monitor 755
for file in core.uc main.uc; do
	copy_file "$BACKEND/usr/share/outbound-monitor/$file" "/usr/share/outbound-monitor/$file" 644
done
if [ ! -e /etc/config/outbound-monitor ]; then
	copy_file "$BACKEND/etc/config/outbound-monitor" /etc/config/outbound-monitor 600
fi
for path in usr/share/rpcd/ucode/outbound-monitor.uc usr/share/rpcd/acl.d/luci-app-outbound-monitor.json usr/share/luci/menu.d/luci-app-outbound-monitor.json; do
	copy_file "$LUCI/$path" "/$path" 644
done
for path in luci-static/resources/view/outbound-monitor/status.js luci-static/resources/outbound-monitor/style.css; do
	copy_file "$WEB/$path" "/www/$path" 644
done
/etc/init.d/outbound-monitor enable
/etc/init.d/outbound-monitor start
# Load the new read-only RPC object with SIGHUP; no network/VPN restart.
/etc/init.d/rpcd reload
echo 'Installed. LuCI: Status -> Outbound Monitor (/cgi-bin/luci/admin/status/outbound-monitor)'
