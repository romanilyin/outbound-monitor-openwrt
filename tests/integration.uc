import { readfile } from 'fs';
let state = json(readfile(ARGV[0]));
function check(ok, message) { if (!ok) die('FAIL integration: ' + message + '\n'); }
check(length(state.keys) == 2, 'two keys');
if (ARGV[1] == 'normal') {
	let one = filter(state.keys, (k) => k.tag == 'one /é')[0];
	let bad = filter(state.keys, (k) => k.tag == 'bad')[0];
	check(one.current == 1 && one.samples[0][2] == 123, 'HTTP delay and encoded tag');
	check(bad.current == 0 && bad.consecutive_failures == 1, 'failure');
	check(state.collector_error == null, 'no collector error');
} else {
	check(length(filter(state.keys, (k) => k.current != -1)) == 0, 'all unknown');
	check(length(filter(state.keys, (k) => k.consecutive_failures != 0)) == 0, 'unknown breaks streak');
	check(type(state.collector_error) == 'string', 'explicit control error');
	if (ARGV[1] == 'rotation') check(index(state.collector_error, 'Configuration changed') >= 0, 'pending config detection');
}
