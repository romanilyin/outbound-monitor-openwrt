// SPDX-License-Identifier: MIT
'use strict';
import { sha256 } from 'digest';

export function encode_path(value) {
	let out = '';
	for (let i = 0; i < length(value); i++) {
		let c = substr(value, i, 1);
		out += match(c, /^[A-Za-z0-9_.~-]$/) ? c : sprintf('%%%02X', ord(c));
	}
	return out;
};

// Sorted recursive serialization keeps identities stable across JSON formatting.
export function canonical(value) {
	if (type(value) == 'object') {
		let parts = [];
		for (let k in sort(keys(value)))
			push(parts, sprintf('%J', k) + ':' + canonical(value[k]));
		return '{' + join(',', parts) + '}';
	}
	if (type(value) == 'array')
		return '[' + join(',', map(value, canonical)) + ']';
	return sprintf('%J', value);
};

export function vpn_link_hash(link) {
	if (type(link) != 'string') return null;
	let value = trim(link);
	let fragment = index(value, '#');
	if (fragment >= 0) value = trim(substr(value, 0, fragment));
	return length(value) ? sha256(value) : null;
};

function connection(o, tag) {
	let value = {};
	for (let name in keys(o)) if (name != 'tag') value[name] = o[name];
	if (tag != null) value.tag = tag;
	return value;
}

export function discover(config, linkmap, interface_map) {
	let by_tag = {}, found = {};
	for (let o in config.outbounds || [])
		if (o.tag) by_tag[o.tag] = o;
	function visit(tag, group, seen) {
		if (seen[tag]) return;
		seen[tag] = true;
		let o = by_tag[tag];
		if (!o) return;
		if (o.type == 'urltest' || o.type == 'selector') {
			for (let child in o.outbounds || []) visit(child, group, seen);
			return;
		}
		if (type(o.type) != 'string' || !length(o.type) || o.type == 'block' || o.type == 'dns') return;
		// An ordinary direct/LAN/WAN outbound is not a VPN key. Interface-bound
		// direct outbounds are monitored only when podkop explicitly maps them.
		let vpn_interface = o.type == 'direct' && type(o.bind_interface) == 'string' &&
			length(o.bind_interface) > 0 && type(interface_map) == 'object' &&
			type(interface_map[o.tag]) == 'string' &&
			interface_map[o.tag] == o.bind_interface;
		if (o.type == 'direct' && !vpn_interface) return;
		// Neither the original VPN link nor credentials leave the config reader.
		let hash = linkmap ? linkmap[o.tag] : null;
		let linked = type(hash) == 'string' && match(hash, /^[a-f0-9]{64}$/);
		// Charts are bound to actual credentials/configuration, never a pending
		// UCI link at the same slot. Keep the observed URI hash as metadata.
		let id = sha256(canonical(connection(o)));
		if (!found[id]) found[id] = {
			id, tag: o.tag, label: o.tag, type: o.type,
			server: o.server ? o.server + (o.server_port ? ':' + o.server_port : '') : '',
			interface: vpn_interface ? o.bind_interface : null,
			link_hash: linked ? hash : null, identity_source: 'outbound_config',
			tags: [], groups: [], active: true, current: -1, samples: [],
			last_checked: null, last_success: null, consecutive_failures: 0
		};
		if (!length(filter(found[id].tags, (tag) => tag == o.tag))) push(found[id].tags, o.tag);
		if (group != null && !length(filter(found[id].groups, (name) => name == group))) push(found[id].groups, group);
	}
	for (let o in config.outbounds || [])
		if (o.tag) visit(o.tag, o.type == 'urltest' || o.type == 'selector' ? o.tag : null, {});
	return map(sort(keys(found)), function(id) {
		let key = found[id];
		key.tags = sort(key.tags);
		key.groups = sort(key.groups);
		key.tag = key.tags[0];
		key.label = key.tag;
		let o = by_tag[key.tag];
		let observed_hash = linkmap ? linkmap[key.tag] : null;
		key.link_hash = type(observed_hash) == 'string' && match(observed_hash, /^[a-f0-9]{64}$/) ? observed_hash : null;
		key.type = o.type;
		key.server = o.server ? o.server + (o.server_port ? ':' + o.server_port : '') : '';
		key.interface = o.type == 'direct' ? o.bind_interface : null;
		return key;
	});
};

// Preserve legacy samples only after matching the complete credential-bearing
// configuration, substituting its old tag. Never infer identity from a server.
export function bind_keys(previous, current, config) {
	let by_tag = {}, legacy = {}, used = {};
	for (let o in config.outbounds || []) if (o.tag) by_tag[o.tag] = o;
	for (let old in previous) {
		old.active = false;
		if (old.identity_source && old.identity_source != 'outbound_config') continue;
		let matches = [];
		for (let item in current) {
			for (let tag in item.tags) {
				let legacy_tag = old.identity_source == 'outbound_config' ? null : old.tag;
				if (old.id == sha256(canonical(connection(by_tag[tag], legacy_tag)))) {
					push(matches, item.id);
					break;
				}
			}
		}
		// Ambiguous legacy identities remain archived instead of guessing.
		if (length(matches) == 1) {
			if (!legacy[matches[0]]) legacy[matches[0]] = [];
			push(legacy[matches[0]], old);
		}
	}
	for (let item in current) {
		let old = filter(previous, (key) => key.id == item.id)[0];
		if (!old) {
			let candidates = sort(legacy[item.id] || [], (a, b) => (b.last_checked || 0) - (a.last_checked || 0));
			old = filter(candidates, (key) => !used[key.id])[0];
		}
		if (old) {
			used[old.id] = true;
			for (let field in ['id', 'tag', 'tags', 'label', 'type', 'server', 'interface', 'groups', 'link_hash', 'identity_source'])
				old[field] = item[field];
			old.active = true;
		} else push(previous, item);
	}
	return previous;
};

export function record(key, timestamp, status, delay, interval) {
	if (status != 1 && status != 0 && status != -2) status = -1;
	let continuous = key.last_checked != null && timestamp >= key.last_checked &&
		timestamp - key.last_checked <= interval * 1.8;
	// A clock step back creates a gap rather than future/duplicate history.
	key.samples = filter(key.samples || [], (s) => s[0] < timestamp);
	if (key.last_success > timestamp) {
		let successes = filter(key.samples, (s) => s[1] == 1);
		key.last_success = length(successes) ? successes[length(successes) - 1][0] : null;
	}
	push(key.samples, [timestamp, status, status == 1 ? delay : null]);
	key.consecutive_failures = status == 0 ? (continuous ? key.consecutive_failures || 0 : 0) + 1 : 0;
	key.current = status;
	key.last_checked = timestamp;
	if (status == 1) key.last_success = timestamp;
};

export function trim_history(state, now, days, interval) {
	let cutoff = now - days * 86400;
	let limit = int(days * 86400 / interval) + 2;
	for (let k in state.keys) {
		k.samples = filter(k.samples || [], (s) => s[0] >= cutoff && s[0] <= now);
		if (length(k.samples) > limit) k.samples = slice(k.samples, -limit);
	}
	state.keys = filter(state.keys, (k) => k.active || length(k.samples));
	// Bound archives too, even if credentials are changed repeatedly.
	let active = filter(state.keys, (k) => k.active);
	let old = sort(filter(state.keys, (k) => !k.active), (a, b) => b.last_checked - a.last_checked);
	state.keys = [...active, ...slice(old, 0, 32)];
};

export function classify(code, body) {
	if (code == 200 && type(body?.delay) == 'int' && body.delay > 0 && body.delay <= 65535)
		return [1, body.delay];
	if (code == 503 || code == 504) return [0, null];
	return [-1, null];
};

// Reject changed config on an observed process. New processes are assumed to
// have loaded the current file; Clash API cannot expose credential identities.
export function config_loaded(previous, generation, fingerprint, link_fingerprint) {
	return generation != null && (previous == null || previous.generation != generation ||
		(previous.fingerprint == fingerprint &&
		(previous.link_fingerprint == null || previous.link_fingerprint == link_fingerprint)));
};
