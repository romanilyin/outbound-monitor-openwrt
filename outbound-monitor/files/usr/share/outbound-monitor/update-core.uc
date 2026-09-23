// SPDX-License-Identifier: MIT
'use strict';
export function parse_version(value) {
	if (value == '0.1.0') return [0, 1, 0, 0];
	if (type(value) != 'string' || !match(value, /^20[0-9]{2}-[1-9][0-9]?-[1-9][0-9]?-[1-9][0-9]*$/)) return null;
	let p = map(split(value, '-'), (x) => int(x));
	return p[1] <= 12 && p[2] <= 31 ? p : null;
};
export function newer(latest, current) {
	let a = parse_version(latest), b = parse_version(current);
	if (!a || !b) return false;
	for (let i = 0; i < 4; i++) if (a[i] != b[i]) return a[i] > b[i];
	return false;
};
export function valid_release(r, format) {
	if (type(r) != 'object' || r.draft || r.prerelease || !parse_version(r.tag_name) || type(r.assets) != 'array') return false;
	let base = 'https://github.com/romanilyin/outbound-monitor-openwrt/releases/download/' + r.tag_name + '/';
	for (let name in ['outbound-monitor.' + format, 'luci-app-outbound-monitor.' + format, 'luci-i18n-outbound-monitor-ru.' + format, 'SHA256SUMS'])
		if (length(filter(r.assets, (a) => a.name == name && a.browser_download_url == base + name)) != 1) return false;
	return true;
};
