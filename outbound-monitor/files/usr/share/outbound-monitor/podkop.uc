// SPDX-License-Identifier: MIT
'use strict';
import { vpn_link_hash } from './core.uc';

// Only hashes and interface names leave the UCI reader, never raw proxy links.
export function section_targets(sections) {
	let links = {}, interfaces = {};
	for (let s in sections || []) {
		let name = s['.name'];
		if (type(name) != 'string' || !length(name)) continue;
		if (s.connection_type == 'vpn') {
			if (type(s.interface) == 'string' && length(s.interface))
				interfaces[name + '-out'] = s.interface;
			continue;
		}
		if (s.connection_type && s.connection_type != 'proxy') continue;
		let mode = s.proxy_config_type || 'url';
		if (mode == 'url') {
			let hash = vpn_link_hash(s.proxy_string);
			if (hash) links[name + '-out'] = hash;
		} else if (mode == 'urltest' || mode == 'selector') {
			let values = s[mode + '_proxy_links'];
			if (type(values) == 'string') values = [values];
			if (type(values) != 'array') continue;
			for (let i = 0; i < length(values); i++) {
				let hash = vpn_link_hash(values[i]);
				if (hash) links[name + '-' + (i + 1) + '-out'] = hash;
			}
		}
	}
	return {links, interfaces};
};
