// SPDX-License-Identifier: MIT
'use strict';
import * as fs from 'fs';
import { cursor } from 'uci';
import { sha256 } from 'digest';
import { discover, bind_keys, record, trim_history, classify, encode_path, canonical, config_loaded, vpn_link_hash } from './core.uc';

import { diagnosis, dns_check } from './network.uc';

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
		dns_check: c.dns_check != '0',
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
function podkop_links() {
	let links = {};
	let u = cursor();
	u.foreach('podkop', 'section', function(section) {
		if (section.proxy_config_type != 'urltest' || type(section.urltest_proxy_links) != 'array') return;
		for (let i = 0; i < length(section.urltest_proxy_links); i++) {
			let hash = vpn_link_hash(section.urltest_proxy_links[i]);
			if (hash) links[section['.name'] + '-' + (i + 1) + '-out'] = hash;
		}
	});
	return links;
}
function direct_outbound(config) {
	// Explicit inherited routing may direct the control through a tunnel.
	if (config?.route?.default_interface || config?.route?.default_mark) return null;
	// A direct outbound bound to a tunnel/interface is not an ISP control.
	let candidates = filter(config?.outbounds || [], (o) => o.type == 'direct' && o.tag &&
		!o.detour && !o.bind_interface && !o.inet4_bind_address && !o.inet6_bind_address && !o.routing_mark);
	let preferred = filter(candidates, (o) => o.tag == 'direct-out');
	return length(preferred) ? preferred[0].tag : length(candidates) == 1 ? candidates[0].tag : null;
}
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
	let dir_stat = fs.lstat(DIR);
	if (dir_stat?.type != 'directory' || dir_stat.uid != 0 || (dir_stat.mode & 0777) != 0700) die('Unsafe state directory\n');
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
	let linkmap = podkop_links();
	let link_fingerprint = sha256(canonical(linkmap));
	let loaded = valid_config && config_loaded(state._runtime, runtime, config_hash, link_fingerprint);
	let current = loaded ? discover(config, linkmap) : [];
	if (length(current) > 32) {
		current = slice(current, 0, 32);
		state.collector_error = 'Monitoring is limited to 32 keys';
	}
	if (loaded) state.keys = bind_keys(state.keys, current, config);
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
	let controls = [], probes = [];
	let direct = direct_outbound(config);
	for (let url in ['https://www.gstatic.com/generate_204', 'https://cp.cloudflare.com/generate_204']) {
		let result = [-1, null];
		if (ready && direct && health.body.proxies[direct]) {
			let r = request(base, '/proxies/' + encode_path(direct) + '/delay',
				['url=' + url, 'timeout=' + (c.timeout * 1000)], c.timeout);
			result = classify(r.code, r.body);
		}
		push(controls, {url, status: result[0], delay: result[1]});
	}
	for (let k in state.keys) {
		if (!k.active) continue;
		let result = [-1, null];
		if (ready && health.body.proxies[k.tag]) {
			let r = request(base, '/proxies/' + encode_path(k.tag) + '/delay',
				['url=' + c.test_url, 'timeout=' + (c.timeout * 1000)], c.timeout);
			result = classify(r.code, r.body);
			if (result[0] == -1) state.collector_error = 'A probe could not be measured (API/control error)';
		} else if (ready) state.collector_error = 'Configuration and running API differ; waiting for matching outbounds';
		push(probes, {key: k, timestamp: time(), status: result[0], delay: result[1]});
	}
	fs.unlink(HEADERS);
	let connectivity = diagnosis(controls, map(probes, (p) => p.status), time());
	connectivity.controls = controls;
	connectivity.direct_tag = direct;
	state.dns_enabled = c.dns_check;
	state.dns_available = !!fs.access('/usr/bin/ipregion', 'x');
	let dns = null;
	if (connectivity.both_controls_failed || !state.dns || !c.dns_check || !state.dns_available)
		dns = dns_check(c.dns_check, controls, DIR, time());
	for (let p in probes)
		record(p.key, p.timestamp, connectivity.common_failure ? -2 : p.status, p.delay, c.interval);
	state.updated_at = time();
	if (runtime != generation() || config_hash != fingerprint(read_json(c.config)) ||
		link_fingerprint != sha256(canonical(podkop_links()))) {
		state.keys = before;
		for (let k in state.keys) if (k.active) record(k, state.updated_at, -1, null, c.interval);
		state.collector_error = 'sing-box changed during collection; measurements discarded';
		state.connectivity = diagnosis([], [], state.updated_at);
	} else {
		if (loaded) state._runtime = {generation: runtime, fingerprint: config_hash, link_fingerprint};
		state.connectivity = connectivity;
		if (dns && (dns.checked_at != null || state.dns?.checked_at == null)) state.dns = dns;
		if (connectivity.both_controls_failed) {
			if (type(state.network_events) != 'array') state.network_events = [];
			push(state.network_events, {checked_at: connectivity.checked_at, connectivity, dns});
		}
	}
	let cutoff = state.updated_at - c.retention_days * 86400;
	state.network_events = filter(state.network_events || [], (e) => e.checked_at >= cutoff && e.checked_at <= state.updated_at);
	state.network_events = slice(state.network_events, -128);
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
		state.network_events = filter(state.network_events || [], (e) => e.checked_at >= cutoff && e.checked_at <= state.now);
		printf('%J\n', state);
		break;
	default: die('Unknown command\n');
}
