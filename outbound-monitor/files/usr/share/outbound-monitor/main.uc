// SPDX-License-Identifier: MIT
'use strict';
import * as fs from 'fs';
import { cursor } from 'uci';
import { sha256 } from 'digest';
import { discover, record, trim_history, classify, encode_path, canonical, config_loaded } from './core.uc';

const DIR = '/tmp/outbound-monitor';
const STATE = DIR + '/state.json';
const HEADERS = DIR + '/headers';

function read_json(path) {
	try { return json(fs.readfile(path)); } catch (e) { return null; }
}
function bounded(value, fallback, low, high) {
	let n = int(value);
	return n == n && n >= low && n <= high ? n : fallback;
}
function settings() {
	let u = cursor();
	let c = u.get_all('outbound-monitor', 'main') || {};
	return {
		interval: bounded(c.interval, 300, 60, 86400),
		retention_days: bounded(c.retention_days, 7, 1, 7),
		timeout: bounded(c.timeout, 8, 1, 30),
		test_url: match(c.test_url || '', /^https:\/\/[^\s]+$/) ? c.test_url : 'https://www.gstatic.com/generate_204',
		config: c.sing_box_config || '/etc/sing-box/config.json'
	};
}
function quote(v) { return "'" + replace('' + v, "'", "'\"'\"'") + "'"; }
function generation() {
	let found = [];
	for (let path in fs.glob('/proc/[0-9]*/comm')) {
		if (trim(fs.readfile(path) || '') != 'sing-box') continue;
		let stat = fs.readfile(replace(path, /comm$/, 'stat')) || '';
		let end = index(stat, ') ');
		if (end >= 0) push(found, path + ':' + split(substr(stat, end + 2), ' ')[19]);
	}
	return length(found) == 1 ? found[0] : null;
}
function fingerprint(config) { return sha256(canonical(config?.outbounds || [])); }
function request(base, path, query, timeout) {
	let args = ['curl', '--silent', '--noproxy', '*', '--proto', '=http',
		'--connect-timeout', '2', '--max-time', '' + (timeout + 2),
		'--max-filesize', '131072', '--header', '@' + HEADERS, '--write-out', '\n%{http_code}', '--get'];
	for (let q in query || []) push(args, '--data-urlencode', q);
	push(args, base + path);
	let p = fs.popen(join(' ', map(args, quote)) + ' 2>/dev/null', 'r');
	let data = p ? p.read('all') : '';
	let exit_code = p ? p.close() : -1;
	let code = exit_code == 0 ? int(substr(data, -3)) : 0;
	let body = null;
	try { body = json(substr(data, 0, length(data) - 4)); } catch (e) {}
	return {code, body};
}
function save(state) {
	let tmp = STATE + '.new';
	if (fs.writefile(tmp, sprintf('%J', state)) == null || !fs.rename(tmp, STATE))
		die('Unable to save outbound monitor history\n');
}
function collect(c) {
	fs.mkdir(DIR, 0700);
	fs.chmod(DIR, 0700);
	let now = time();
	let state = read_json(STATE);
	if (state?.version != 1 || type(state.keys) != 'array') state = {version: 1, keys: []};
	state.interval = c.interval;
	state.retention_days = c.retention_days;
	state.timeout = c.timeout;
	state.test_url = c.test_url;
	state.storage = 'ram';
	state.collector_error = null;
	let config = read_json(c.config);
	let api = config?.experimental?.clash_api;
	let address = api?.external_controller;
	let valid_config = type(config?.outbounds) == 'array';
	let runtime = generation();
	let config_hash = fingerprint(config);
	let loaded = valid_config && config_loaded(state._runtime, runtime, config_hash);
	let current = loaded ? discover(config) : [];
	if (length(current) > 32) {
		current = slice(current, 0, 32);
		state.collector_error = 'Monitoring is limited to 32 keys';
	}
	if (loaded) {
		for (let k in state.keys) k.active = false;
		for (let item in current) {
			let old = filter(state.keys, (k) => k.id == item.id)[0];
			if (old) {
				old.active = true;
				old.groups = item.groups;
			} else push(state.keys, item);
		}
	}
	let base = null;
	if (type(address) == 'string' && match(address, /^(\[[0-9a-fA-F:]+\]|[A-Za-z0-9_.-]+):[0-9]+$/)) {
		address = replace(address, /^0\.0\.0\.0:/, '127.0.0.1:');
		address = replace(address, /^\[::\]:/, '[::1]:');
		base = 'http://' + address;
	}
	// Keep API credentials out of process command lines and RPC responses.
	let secret = api?.secret || '';
	if (match(secret, /[\r\n]/)) base = null;
	if (fs.writefile(HEADERS, secret ? 'Authorization: Bearer ' + secret + '\n' : '') == null)
		die('Unable to create private API headers\n');
	fs.chmod(HEADERS, 0600);
	let health = base ? request(base, '/proxies', [], 3) : null;
	let ready = loaded && health?.code == 200 && type(health.body?.proxies) == 'object';
	if (!ready) state.collector_error = !valid_config ? 'Cannot read sing-box configuration' :
		!runtime ? 'A unique running sing-box process was not found' :
		!loaded ? 'Configuration changed; waiting for sing-box to load it' :
		!base ? 'Clash API is not configured' : 'Clash API unavailable (HTTP ' + (health?.code || 0) + ')';
	let before = json(sprintf('%J', state.keys));
	for (let k in state.keys) {
		if (!k.active) continue;
		let result = [-1, null];
		if (ready && health.body.proxies[k.tag]) {
			let r = request(base, '/proxies/' + encode_path(k.tag) + '/delay',
				['url=' + c.test_url, 'timeout=' + (c.timeout * 1000)], c.timeout);
			result = classify(r.code, r.body);
			if (result[0] == -1) state.collector_error = 'A probe could not be measured (API/control error)';
		} else if (ready) state.collector_error = 'Configuration and running API differ; waiting for matching outbounds';
		record(k, time(), result[0], result[1], c.interval);
	}
	fs.unlink(HEADERS);
	state.updated_at = time();
	if (runtime != generation() || config_hash != fingerprint(read_json(c.config))) {
		state.keys = before;
		for (let k in state.keys) if (k.active) record(k, state.updated_at, -1, null, c.interval);
		state.collector_error = 'sing-box changed during collection; measurements discarded';
	} else if (loaded) state._runtime = {generation: runtime, fingerprint: config_hash};
	trim_history(state, state.updated_at, c.retention_days, c.interval);
	save(state);
}

let c = settings();
switch (ARGV[0]) {
	case 'interval': print(c.interval); break;
	case 'collect': collect(c); break;
	case 'status':
		let state = read_json(STATE) || {version: 1, keys: [], updated_at: null};
		state.now = time();
		state.interval = c.interval;
		state.retention_days = c.retention_days;
		state.timeout = c.timeout;
		state.test_url = c.test_url;
		state.storage = 'ram';
		delete state._runtime;
		let cutoff = state.now - bounded(ARGV[1], 24, 1, 168) * 3600;
		for (let k in state.keys) k.samples = filter(k.samples, (s) => s[0] >= cutoff && s[0] <= state.now);
		printf('%J\n', state);
		break;
	default: die('Unknown command\n');
}
