// Pure tests; no network requests, config changes or service operations.
import { diagnosis, summarize_dns, dns_check } from '../outbound-monitor/files/usr/share/outbound-monitor/network.uc';
let count = 0;
function check(ok, message) { if (!ok) die('FAIL network: ' + message + '\n'); count++; }
let d = diagnosis([{status:0}, {status:0}], [0, 0, 0], 100);
check(d.status == 0 && d.reason == 'direct_failed' && d.common_failure && d.both_controls_failed && d.checked_at == 100, 'all failures indicate probable common failure');
for (let statuses in [[], [-1], [0, -1], [1], [0, 1]])
	check(!diagnosis([0, 0], statuses, 100).common_failure, 'empty, unknown or working VPN prevents common failure');
d = diagnosis([0, 0], [0, 1], 100);
check(d.status == 0 && d.reason == 'mixed' && d.both_controls_failed, 'working VPN with failed direct controls is mixed');
for (let controls in [[-1, -1], [0, -1], [0], [], [0, 0, 0], [null, 0], ['0', 0]]) {
	d = diagnosis(controls, [0, 0], 100);
	check(d.status == -1 && d.reason == 'api_error' && !d.common_failure && !d.both_controls_failed, 'missing or unknown controls stay unknown');
}
d = diagnosis([{status:1,delay:120}, {status:1,delay:20}], [0, 0], 100);
check(d.status == 1 && d.reason == 'ok' && d.delay == 20 && !d.common_failure, 'working control excludes common failure');
check(diagnosis([1, -1], [-1], 100).status == 1, 'one known direct success establishes reachability');
check(dns_check(false, [0,0], '/not-used', 100).status == 'disabled', 'disabled DNS performs no command');

function row(id, status, dot, doh) {
	return {id, name:'Resolver', status, dot:{status:dot,answers:['secret-answer'],error:'secret-error'},
		doh:{status:doh}, address:'secret-address', query_name:'secret-query'};
}
let raw = {version:1, mode:'dns', resolvers:[row('one','ok','ok','ok')], errors:[], summary:{ok:999}};
let s = summarize_dns(raw, 123);
check(s.status == 'ok' && s.checked_at == 123 && s.route == 'router' && s.summary.ok == 1, 'valid result uses derived compact summary');
check(s.resolvers[0].dot == 'ok' && s.resolvers[0].doh == 'ok', 'compact DoT and DoH status strings');
check(index(sprintf('%J', s), 'secret-') == -1, 'raw DNS answers, addresses, query and errors omitted');
raw.resolvers = [row('one','mismatch','ok','nxdomain'),row('two','partial','ok','timeout'),row('three','failed','tls_failed','network_failed')];
s = summarize_dns(raw, 123);
check(s.status == 'issues' && s.summary.mismatch == 1 && s.summary.warning == 1 && s.summary.failed == 1, 'DNS issue classes preserved without ISP conclusion');
raw.resolvers[0].dot.status = 'running';
check(summarize_dns(raw, 123).status == 'error', 'partial running output is not a completed result');
raw.resolvers = [row('one','ok','ok','ok')]; raw.errors = [{message:'secret-raw-error'}];
s = summarize_dns(raw, 123);
check(s.status == 'error' && index(sprintf('%J',s), 'secret-') == -1, 'CLI errors summarized safely');
for (let value in [null, {}, {version:1,mode:'dns',resolvers:[]}, {version:1,mode:'other',resolvers:raw.resolvers}])
	check(summarize_dns(value, 123).status == 'error', 'invalid result is an error');
function probe(id, ip, transport, status) {
	return {id, name:'Resolver', ip_version:ip, transport, status, answers:['secret-answer'],address:'secret-address'};
}
raw = {version:2, mode:'dns', probes:[probe('one',4,'udp','ok'),probe('one',4,'tcp','ok'),
	probe('one',4,'dot','ok'),probe('one',4,'doh','ok'),probe('one',6,'udp','timeout'),
	probe('interface_dns',4,'udp','ok'),probe('interface_dns',4,'tcp','timeout')],
	summary:{status:'warning',findings:['secret-text'],finding_details:[{code:'udp_unavailable',name:'secret-label'},{code:'unknown-secret-code'}]},errors:[]};
s = summarize_dns(raw, 123);
check(s.status == 'issues' && length(s.resolvers) == 3 && s.summary.ok == 1 && s.summary.warning == 1 && s.summary.failed == 1, 'v2 groups by resolver and IP version');
check(s.resolvers[0].ip_version == 4 && s.resolvers[1].ip_version == 6 && s.resolvers[2].dot == 'not_tested' && s.resolvers[2].doh == 'not_tested', 'v2 missing transports distinguished');
check(length(s.findings) == 1 && s.findings[0] == 'udp_unavailable' && index(sprintf('%J',s),'secret-') == -1, 'v2 compact diagnostic codes only');
raw.probes = [probe('one',4,'udp','ok'),probe('one',4,'doh','ok')];
raw.summary.finding_details = [{code:'plain_answer_mismatch'}];
check(summarize_dns(raw,123).status == 'issues' && summarize_dns(raw,123).summary.ok == 1, 'v2 summary warning survives successful individual probes');
raw.summary = {status:'ok'};
check(summarize_dns(raw,123).status == 'ok', 'v2 completed successful result');
raw.probes[0].status = 'running';
check(summarize_dns(raw,123).status == 'error', 'v2 unfinished probe rejected');
raw.probes = [probe('one',4,'udp','ok'),probe('one',4,'udp','timeout')];
check(summarize_dns(raw,123).status == 'error', 'v2 duplicate transport rejected');
printf('PASS %d network assertions\n', count);
