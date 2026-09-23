import { readfile, writefile } from 'fs';
import { sha256 } from 'digest';
let state = json(readfile(ARGV[0]));
function check(ok, message) { if (!ok) die('FAIL integration: ' + message + '\n'); }
let a_id = sha256('{"server":"alpha.example","type":"vless","uuid":"fake-uuid-a"}');
let b_id = sha256('{"server":"beta.example","type":"vless","uuid":"fake-uuid-b"}');
let c_id = sha256('{"server":"beta.example","type":"vless","uuid":"fake-uuid-c"}');
if (ARGV[1] == 'seed-history') {
	let now = time();
	for (let key in state.keys) {
		key.samples = [[now-900,1,111], [now-600,1,112], [now-300,1,113]];
		key.last_checked = now-300; key.last_success = now-300; key.current = 1;
	}
	writefile(ARGV[0] + '.expected', sprintf('%J', state.keys[0].samples));
	writefile(ARGV[0], sprintf('%J', state));
} else if (ARGV[1] == 'reordered' || ARGV[1] == 'replaced' || ARGV[1] == 'linkrace') {
	let a = filter(state.keys, (key) => key.id == a_id)[0];
	let b = filter(state.keys, (key) => key.id == b_id)[0];
	let expected = json(readfile(ARGV[0] + '.expected'));
	check(a.active && a.tag == 'vpn-2-out' && a.label == a.tag && a.server == 'alpha.example', 'A metadata follows current position');
	check(sprintf('%J', slice(a.samples,0,3)) == sprintf('%J', expected), 'A retains the three original samples');
	check(sprintf('%J', slice(b.samples,0,3)) == sprintf('%J', expected), 'B retains the three original samples');
	check(a.link_hash == 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' && a.identity_source == 'outbound_config', 'only link digest is persisted');
	if (ARGV[1] == 'reordered') {
		check(length(state.keys) == 2 && b.active && b.tag == 'vpn-1-out', 'both keys rebind without archive');
		check(a.samples[length(a.samples)-1][2] == 456 && b.samples[length(b.samples)-1][2] == 123,
			'collector probes each current API alias after reordering');
	} else {
		let c = filter(state.keys, (key) => key.id == c_id)[0];
		check(length(state.keys) == 3 && !b.active && c.active && c.tag == 'vpn-1-out', 'only replaced B is archived');
		if (ARGV[1] == 'linkrace') {
			check(a.current == -1 && c.current == -1 && index(state.collector_error, 'changed during collection') >= 0,
				'link change during probes discards measurements');
		} else check(length(c.samples) == 1 && c.current == 1, 'replacement begins fresh history');
	}
} else if (ARGV[1] == 'normal') {
	check(length(state.keys) == 2, 'two keys');
	let one = filter(state.keys, (k) => k.tag == 'one /é')[0];
	let bad = filter(state.keys, (k) => k.tag == 'bad')[0];
	check(one.current == 1 && one.samples[0][2] == 123, 'HTTP delay and encoded tag');
	check(bad.current == 0 && bad.consecutive_failures == 1, 'failure');
	check(state.collector_error == null, 'no collector error');
} else {
	check(length(state.keys) == 2, 'two keys');
	check(length(filter(state.keys, (k) => k.current != -1)) == 0, 'all unknown');
	check(length(filter(state.keys, (k) => k.consecutive_failures != 0)) == 0, 'unknown breaks streak');
	check(type(state.collector_error) == 'string', 'explicit control error');
	if (ARGV[1] == 'rotation' || ARGV[1] == 'pending-identity')
		check(index(state.collector_error, 'Configuration changed') >= 0, 'pending config or UCI link detection');
	if (ARGV[1] == 'pending-identity') check(length(filter(state.keys, (key) => key.id == a_id || key.id == b_id)) == 2,
		'pending UCI never assigns a new link identity before apply');
}
