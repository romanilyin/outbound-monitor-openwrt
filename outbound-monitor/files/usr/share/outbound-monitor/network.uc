// SPDX-License-Identifier: MIT
'use strict';
import * as fs from 'fs';

const IPREGION = '/usr/bin/ipregion';
const IPREGION_SCRIPT = '/usr/share/ipregion/ipregion.uc';
const DNS_TIMEOUT = 25000;
const DNS_STATUSES = ['ok', 'mismatch', 'nxdomain', 'dns_error', 'no_answer',
	'partial', 'failed', 'timeout', 'tls_failed', 'network_failed', 'unavailable'];
const DNS_TRANSPORTS = ['udp', 'tcp', 'dot', 'doh'];
const DNS_FINDINGS = ['plain_answer_mismatch', 'udp_unavailable', 'tcp_unavailable', 'both_unavailable'];

function probe_status(probe) {
	let value = type(probe) == 'object' ? probe.status : probe;
	return type(value) == 'int' && (value == 0 || value == 1) ? value : -1;
}

// Control failures describe reachability, never prove an ISP fault. An unknown
// API result must not be promoted into a failed direct or VPN probe.
export function diagnosis(controls, vpn_statuses, timestamp) {
	controls = type(controls) == 'array' ? controls : [];
	vpn_statuses = type(vpn_statuses) == 'array' ? vpn_statuses : [];
	let both_failed = length(controls) == 2 &&
		length(filter(controls, (p) => probe_status(p) == 0)) == 2;
	let any_direct = length(filter(controls, (p) => probe_status(p) == 1)) > 0;
	let any_vpn = length(filter(vpn_statuses, (p) => probe_status(p) == 1)) > 0;
	let common = both_failed && length(vpn_statuses) > 0 &&
		length(filter(vpn_statuses, (p) => probe_status(p) == 0)) == length(vpn_statuses);
	let result = {
		checked_at: timestamp,
		status: any_direct ? 1 : both_failed ? 0 : -1,
		reason: any_direct ? 'ok' : both_failed ? (any_vpn ? 'mixed' : 'direct_failed') : 'api_error',
		common_failure: common,
		both_controls_failed: both_failed
	};
	let delays = map(filter(controls, (p) => type(p) == 'object' && probe_status(p) == 1 &&
		type(p.delay) == 'int' && p.delay > 0), (p) => p.delay);
	if (length(delays)) result.delay = sort(delays, (a, b) => a - b)[0];
	return result;
};

function dns_result(status, timestamp, error) {
	return { checked_at: timestamp, status, error: error || null, route: 'router',
		summary: {ok: 0, mismatch: 0, warning: 0, failed: 0}, resolvers: [] };
}

function compact_status(value) {
	return type(value) == 'string' && index(DNS_STATUSES, value) >= 0 ? value : 'unknown';
}

function v2_resolvers(raw) {
	if (type(raw.probes) != 'array' || !length(raw.probes) || length(raw.probes) > 64) return null;
	let groups = {}, order = [];
	for (let probe in raw.probes) {
		if (type(probe) != 'object' || type(probe.id) != 'string' || !length(probe.id) ||
			(probe.ip_version !== 4 && probe.ip_version !== 6) || index(DNS_TRANSPORTS, probe.transport) < 0) return null;
		let key = probe.id + ':' + probe.ip_version;
		if (!groups[key]) {
			if (length(order) >= 16) return null;
			groups[key] = {id: substr(probe.id, 0, 64), ip_version: probe.ip_version,
				name: type(probe.name) == 'string' ? substr(probe.name, 0, 80) : '',
				udp: 'not_tested', tcp: 'not_tested', dot: 'not_tested', doh: 'not_tested'};
			push(order, key);
		}
		// Ambiguous duplicates must not let a later success hide a failed probe.
		if (groups[key][probe.transport] != 'not_tested') return null;
		groups[key][probe.transport] = compact_status(probe.status);
	}
	return map(order, function(key) {
		let item = groups[key];
		let statuses = filter(map(DNS_TRANSPORTS, (name) => item[name]), (s) => s != 'not_tested');
		let passed = length(filter(statuses, (s) => s == 'ok'));
		item.status = index(statuses, 'unknown') >= 0 ? 'unknown' :
			passed == length(statuses) ? 'ok' : passed ? 'partial' : 'failed';
		return item;
	});
}

// Keep only bounded labels and status enums. No DNS answers, resolver addresses,
// raw dig output, query names or upstream error messages enter monitor history.
export function summarize_dns(raw, timestamp) {
	let result = dns_result('error', timestamp, 'Invalid IPRegion DNS result.');
	if ((raw?.version != 1 && raw?.version != 2) || raw.mode != 'dns') return result;
	let rows = raw.version == 2 ? v2_resolvers(raw) : raw.resolvers;
	if (type(rows) != 'array' || length(rows) == 0 || length(rows) > 16) return result;
	let incomplete = false;
	for (let row in rows) {
		if (type(row) != 'object') return result;
		let item = raw.version == 2 ? row : {
			id: type(row.id) == 'string' ? substr(row.id, 0, 64) : '',
			name: type(row.name) == 'string' ? substr(row.name, 0, 80) : '',
			status: compact_status(row.status),
			udp: 'not_tested', tcp: 'not_tested',
			dot: compact_status(row.dot?.status), doh: compact_status(row.doh?.status)
		};
		push(result.resolvers, item);
		if (item.status == 'ok') result.summary.ok++;
		else if (item.status == 'mismatch') result.summary.mismatch++;
		else if (item.status == 'failed') result.summary.failed++;
		else result.summary.warning++;
		if (!length(item.id) || item.status == 'unknown' || item.dot == 'unknown' || item.doh == 'unknown') incomplete = true;
	}
	if (incomplete || (type(raw.errors) == 'array' && length(raw.errors))) {
		result.error = 'IPRegion DNS diagnostics were incomplete or unavailable.';
		return result;
	}
	result.status = result.summary.ok == length(result.resolvers) ? 'ok' : 'issues';
	if (raw.version == 2) {
		// Answer comparisons can warn even when every individual query succeeded.
		if (raw.summary?.status && raw.summary.status != 'ok') result.status = 'issues';
		if (type(raw.summary?.finding_details) == 'array') {
			result.findings = [];
			for (let finding in raw.summary.finding_details)
				if (index(DNS_FINDINGS, finding?.code) >= 0 && index(result.findings, finding.code) < 0)
					push(result.findings, finding.code);
			if (length(result.findings)) result.status = 'issues';
		}
	}
	result.error = null;
	return result;
};

function safe_directory(path) {
	let st = type(path) == 'string' ? fs.lstat(path) : null;
	return st?.type == 'directory' && st.uid == 0 && (st.mode & 0777) == 0700;
}

function quote(value) { return "'" + replace(value, "'", "'\"'\"'") + "'"; }

// IPRegion's DNS CLI writes progress even with --no-uci. A private runtime
// directory is mandatory to avoid touching its own status/history. These DNS
// probes use the router's route, which may traverse VPN policy; unlike the
// caller's HTTPS controls they are not guaranteed to use the direct outbound.
export function dns_check(enabled, controls, safe_dir, timestamp) {
	if (enabled === false || enabled === 0 || enabled === '0') return dns_result('disabled', null, null);
	if (!fs.access(IPREGION, 'x')) return dns_result('not_installed', null, null);
	if (!diagnosis(controls, [], timestamp).both_controls_failed) return dns_result('not_run', null, null);
	if (!safe_directory(safe_dir)) return dns_result('error', timestamp, 'Unsafe DNS diagnostics directory.');
	let script = fs.readfile(IPREGION_SCRIPT) || '';
	if (!match(script, /getenv\(\s*['"]IPREGION_RUNTIME_DIR['"]\s*\)/))
		return dns_result('error', timestamp, 'Installed IPRegion lacks isolated DNS diagnostics support.');
	let work = fs.mkdtemp(safe_dir + '/dns-XXXXXX');
	if (!work || !safe_directory(work)) return dns_result('error', timestamp, 'Cannot create private DNS diagnostics directory.');
	let output = work + '/result.json';
	let result;
	try {
		let args = ['env', 'IPREGION_RUNTIME_DIR=' + work, IPREGION, 'dns', '--no-uci',
			'--timeout', '2', '--retries', '0', '--output', output];
		// exec makes system()'s deadline target IPRegion, not an intermediate shell.
		let code = system('exec ' + join(' ', map(args, quote)) + ' >/dev/null 2>&1', DNS_TIMEOUT);
		let st = fs.lstat(output);
		let raw = st?.type == 'file' && st.size <= 262144 ? json(fs.readfile(output)) : null;
		result = summarize_dns(raw, timestamp);
		if (code != 0 && code != 1) {
			result.status = 'error';
			result.error = code == -9 ? 'DNS diagnostics exceeded the time limit.' : 'IPRegion DNS diagnostics could not complete.';
		}
	} catch (e) {
		result = dns_result('error', timestamp, 'Cannot read IPRegion DNS diagnostics.');
	}
	// This directory was freshly created here. IPRegion only creates flat files.
	for (let path in fs.glob(work + '/*')) fs.unlink(path);
	fs.rmdir(work);
	return result;
};
