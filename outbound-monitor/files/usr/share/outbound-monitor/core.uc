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

export function discover(config) {
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
		if (o.type == 'direct' || o.type == 'block' || o.type == 'dns') return;
		// Only a digest, public endpoint and metadata leave the config reader.
		let id = sha256(canonical(o));
		if (!found[id]) found[id] = {
			id, tag: o.tag, label: o.tag, type: o.type,
			server: o.server ? o.server + (o.server_port ? ':' + o.server_port : '') : '',
			groups: [], active: true, current: -1, samples: [],
			last_checked: null, last_success: null, consecutive_failures: 0
		};
		push(found[id].groups, group);
	}
	for (let o in config.outbounds || [])
		if (o.type == 'urltest') visit(o.tag, o.tag, {});
	return map(sort(keys(found)), (id) => found[id]);
};

export function record(key, timestamp, status, delay, interval) {
	if (status != 1 && status != 0) status = -1;
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
export function config_loaded(previous, generation, fingerprint) {
	return generation != null && (previous == null || previous.generation != generation || previous.fingerprint == fingerprint);
};
