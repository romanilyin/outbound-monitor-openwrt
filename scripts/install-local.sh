#!/bin/sh
# SPDX-License-Identifier: MIT
# Source install for opkg and apk systems; only this plugin's files are copied.
set -eu
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ -d "$ROOT/../outbound-monitor" ] && ROOT=$(CDPATH= cd -- "$ROOT/.." && pwd)
[ "$(id -u)" = 0 ] || { echo 'Run as root on OpenWrt' >&2; exit 1; }
for tool in ucode curl flock ubus; do
	command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }
done
ucode -e 'import * as fs from "fs"; import * as uci from "uci"; import * as digest from "digest";'
[ -f /usr/lib/rpcd/ucode.so ] || { echo 'Missing rpcd-mod-ucode' >&2; exit 1; }
[ -d /www/luci-static/resources ] || { echo 'LuCI is required' >&2; exit 1; }
if [ ! -e /tmp/outbound-monitor ] && [ ! -L /tmp/outbound-monitor ]; then mkdir -m 700 /tmp/outbound-monitor; fi
[ -d /tmp/outbound-monitor ] && [ ! -L /tmp/outbound-monitor ] && \
	ucode -e 'import * as fs from "fs"; let d=fs.lstat("/tmp/outbound-monitor"); exit(d?.type == "directory" && d.uid == 0 && (d.mode & 0777) == 0700 ? 0 : 1);'  || { echo 'Unsafe state directory' >&2; exit 1; }
[ ! -L /tmp/outbound-monitor/package.lock ] || exit 1
exec 8>/tmp/outbound-monitor/package.lock
flock -n 8 || { echo 'Another installation is running' >&2; exit 1; }
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
for path in usr/bin/outbound-monitor usr/bin/outbound-monitor-update usr/share/outbound-monitor/core.uc usr/share/outbound-monitor/network.uc usr/share/outbound-monitor/main.uc usr/share/outbound-monitor/update.uc usr/share/outbound-monitor/update-core.uc etc/init.d/outbound-monitor etc/config/outbound-monitor; do
	[ -f "$BACKEND/$path" ] || { echo "Missing payload: $path" >&2; exit 1; }
done
for path in usr/share/rpcd/ucode/outbound-monitor.uc usr/share/rpcd/acl.d/luci-app-outbound-monitor.json usr/share/luci/menu.d/luci-app-outbound-monitor.json; do
	[ -f "$LUCI/$path" ] || { echo "Missing payload: $path" >&2; exit 1; }
done
for path in luci-static/resources/view/outbound-monitor/status.js luci-static/resources/outbound-monitor/style.css; do
	[ -f "$WEB/$path" ] || { echo "Missing payload: $path" >&2; exit 1; }
done
HAD_SERVICE=0; WAS_RUNNING=0; WAS_ENABLED=0
if [ -x /etc/init.d/outbound-monitor ]; then
	HAD_SERVICE=1
	/etc/init.d/outbound-monitor running >/dev/null 2>&1 && WAS_RUNNING=1
	/etc/init.d/outbound-monitor enabled >/dev/null 2>&1 && WAS_ENABLED=1
	/etc/init.d/outbound-monitor stop
fi
restore_service() {
	result=$?
	if [ "$HAD_SERVICE" = 0 ] || [ "$WAS_ENABLED" = 1 ]; then /etc/init.d/outbound-monitor enable
	else /etc/init.d/outbound-monitor disable; fi
	if [ "$HAD_SERVICE" = 0 ] || [ "$WAS_RUNNING" = 1 ]; then /etc/init.d/outbound-monitor restart
	else /etc/init.d/outbound-monitor stop; fi
	exit "$result"
}
trap restore_service EXIT
trap 'exit 1' HUP INT TERM
copy_file() {
	source=$1 dest=$2 mode=$3
	mkdir -p "$(dirname "$dest")"
	cp "$source" "$dest"
	chmod "$mode" "$dest"
}
copy_file "$BACKEND/usr/bin/outbound-monitor" /usr/bin/outbound-monitor 755
copy_file "$BACKEND/usr/bin/outbound-monitor-update" /usr/bin/outbound-monitor-update 755
copy_file "$BACKEND/etc/init.d/outbound-monitor" /etc/init.d/outbound-monitor 755
for file in core.uc main.uc network.uc update.uc update-core.uc; do
	copy_file "$BACKEND/usr/share/outbound-monitor/$file" "/usr/share/outbound-monitor/$file" 644
done
if [ -d "$ROOT/files" ]; then
	copy_file "$BACKEND/usr/share/outbound-monitor/version" /usr/share/outbound-monitor/version 644
	copy_file "$BACKEND/usr/share/outbound-monitor/install.sh" /usr/share/outbound-monitor/install.sh 755
else
	copy_file "$ROOT/VERSION" /usr/share/outbound-monitor/version 644
	copy_file "$ROOT/install.sh" /usr/share/outbound-monitor/install.sh 755
fi
if [ ! -e /etc/config/outbound-monitor ]; then
	copy_file "$BACKEND/etc/config/outbound-monitor" /etc/config/outbound-monitor 600
fi
for path in usr/share/rpcd/ucode/outbound-monitor.uc usr/share/rpcd/acl.d/luci-app-outbound-monitor.json usr/share/luci/menu.d/luci-app-outbound-monitor.json; do
	copy_file "$LUCI/$path" "/$path" 644
done
for path in luci-static/resources/view/outbound-monitor/status.js luci-static/resources/outbound-monitor/style.css; do
	copy_file "$WEB/$path" "/www/$path" 644
done
# Reload only rpcd to register status and explicit update methods.
/etc/init.d/rpcd reload
echo 'Installed. LuCI: Status -> Outbound Monitor (/cgi-bin/luci/admin/status/outbound-monitor)'
