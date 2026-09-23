#!/bin/sh
# SPDX-License-Identifier: MIT
# Install/upgrade only Outbound Monitor packages from the official GitHub release.
set -eu
umask 077
REPO=romanilyin/outbound-monitor-openwrt
RELEASE=${OUTBOUND_MONITOR_RELEASE:-latest}
die() { echo "outbound-monitor: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die 'Run as root on OpenWrt'
for cmd in curl ucode sha256sum flock mktemp; do
	command -v "$cmd" >/dev/null || die "Missing dependency: $cmd (install it from the OpenWrt feed)"
done
if command -v apk >/dev/null; then FORMAT=apk
elif command -v opkg >/dev/null; then FORMAT=ipk
else die 'Neither apk nor opkg is installed'; fi
if [ "$RELEASE" != latest ]; then
	printf '%s\n' "$RELEASE" | grep -Eq '^20[0-9]{2}-[1-9][0-9]?-[1-9][0-9]?-[1-9][0-9]*$' || die 'Invalid release tag; expected YYYY-M-D-N'
fi
if [ ! -e /tmp/outbound-monitor ] && [ ! -L /tmp/outbound-monitor ]; then mkdir -m 700 /tmp/outbound-monitor; fi
[ -d /tmp/outbound-monitor ] && [ ! -L /tmp/outbound-monitor ] && \
	ucode -e 'import * as fs from "fs"; let d=fs.lstat("/tmp/outbound-monitor"); exit(d?.type == "directory" && d.uid == 0 && (d.mode & 0777) == 0700 ? 0 : 1);'  || die 'Unsafe /tmp/outbound-monitor directory'
[ ! -L /tmp/outbound-monitor/package.lock ] || die 'Unsafe package lock'
exec 8>/tmp/outbound-monitor/package.lock
flock -n 8 || die 'Another package installation is running'
WORK=$(mktemp -d /tmp/outbound-monitor-install.XXXXXX)
WAS_RUNNING=0; WAS_ENABLED=0; HAD_SERVICE=0; STOPPED=0
if [ -x /etc/init.d/outbound-monitor ]; then
	HAD_SERVICE=1
	/etc/init.d/outbound-monitor running >/dev/null 2>&1 && WAS_RUNNING=1
	/etc/init.d/outbound-monitor enabled >/dev/null 2>&1 && WAS_ENABLED=1
fi
cleanup() {
	result=$?
	if [ "$STOPPED" = 1 ]; then
		if [ -f "$WORK/config" ]; then cp "$WORK/config" /etc/config/outbound-monitor; fi
		if [ -x /etc/init.d/outbound-monitor ]; then
			if [ "$HAD_SERVICE" = 0 ] || [ "$WAS_ENABLED" = 1 ]; then /etc/init.d/outbound-monitor enable
			else /etc/init.d/outbound-monitor disable; fi
			if [ "$HAD_SERVICE" = 0 ] || [ "$WAS_RUNNING" = 1 ]; then /etc/init.d/outbound-monitor restart
			else /etc/init.d/outbound-monitor stop; fi
		fi
	fi
	rm -rf "$WORK"
	exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
download() {
	curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
		--connect-timeout 10 --max-time 120 --max-filesize 8388608 --retry 2 --retry-delay 2 \
		--output "$2" "$1"
}
if [ "$RELEASE" = latest ]; then API="https://api.github.com/repos/$REPO/releases/latest"
else API="https://api.github.com/repos/$REPO/releases/tags/$RELEASE"; fi
download "$API" "$WORK/release.json" || die 'Cannot fetch GitHub release metadata'
TAG=$(ucode -e '
import { readfile } from "fs";
let r; try { r = json(readfile(ARGV[0])); } catch(e) { exit(1); }
if (r.draft || r.prerelease || !match(r.tag_name || "", /^20[0-9]{2}-[1-9][0-9]?-[1-9][0-9]?-[1-9][0-9]*$/)) exit(1);
print(r.tag_name);
' "$WORK/release.json") || die 'Release is missing, unstable, or has an invalid tag'
[ "$RELEASE" = latest ] || [ "$TAG" = "$RELEASE" ] || die 'Release metadata does not match the requested tag'
BASE="https://github.com/$REPO/releases/download/$TAG"
download "$BASE/SHA256SUMS" "$WORK/SHA256SUMS" || die 'Missing release checksums'
for pkg in outbound-monitor luci-app-outbound-monitor luci-i18n-outbound-monitor-ru; do
	name="$pkg.$FORMAT"
	download "$BASE/$name" "$WORK/$name" || die "Cannot download $name"
	expected=$(awk -v name="$name" '$2 == name { print $1 }' "$WORK/SHA256SUMS")
	[ "${#expected}" = 64 ] || die "Missing or ambiguous checksum for $name"
	case "$expected" in *[!0-9a-f]*) die "Invalid checksum for $name" ;; esac
	actual=$(sha256sum "$WORK/$name" | awk '{ print $1 }')
	[ "$actual" = "$expected" ] || die "Checksum mismatch for $name; nothing installed"
done
echo "Installing Outbound Monitor $TAG ($FORMAT)"
# Refresh indexes only; never upgrade unrelated installed packages.
if [ "$FORMAT" = apk ]; then apk update; else opkg update; fi
if [ -f /etc/config/outbound-monitor ]; then cp /etc/config/outbound-monitor "$WORK/config"; fi
STOPPED=1
if [ "$HAD_SERVICE" = 1 ]; then /etc/init.d/outbound-monitor stop; fi
if [ "$FORMAT" = apk ]; then
	apk add --allow-untrusted "$WORK/outbound-monitor.apk" "$WORK/luci-app-outbound-monitor.apk" "$WORK/luci-i18n-outbound-monitor-ru.apk"
else
	opkg install "$WORK/outbound-monitor.ipk" "$WORK/luci-app-outbound-monitor.ipk" "$WORK/luci-i18n-outbound-monitor-ru.ipk"
fi
[ "$(cat /usr/share/outbound-monitor/version)" = "$TAG" ] || die 'Installed version did not match the release'
/etc/init.d/rpcd reload
echo "Installed $TAG. LuCI: Status -> Outbound Monitor. Reload the browser page."
