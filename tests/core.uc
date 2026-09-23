// Run from the repository with ucode tests/core.uc. No network or config changes.
import { canonical, discover, record, trim_history, classify, encode_path, config_loaded } from '../outbound-monitor/files/usr/share/outbound-monitor/core.uc';
let count = 0;
function check(ok, message) {
	if (!ok) die('FAIL: ' + message + '\n');
	count++;
}
check(canonical({b: 1, a: {z: 2, x: 3}}) == canonical({a: {x: 3, z: 2}, b: 1}), 'canonical object order');
let config = {outbounds: [
	{type:'urltest', tag:'group', outbounds:['selector', 'direct', 'missing']},
	{type:'selector', tag:'selector', outbounds:['a', 'b', 'group']},
	{type:'direct', tag:'direct'},
	{type:'vless', tag:'a', server:'example.test', uuid:'secret-a'},
	{type:'hysteria2', tag:'b', server:'other.test', password:'secret-b'}
]};
check(encode_path('vpn /#%?é') == 'vpn%20%2F%23%25%3F%C3%A9', 'UTF-8 path encoding');
let keys = discover(config);
check(length(keys) == 2, 'nested groups, dedup, cycle, exclusions');
check(index(sprintf('%J', keys), 'secret-') == -1, 'no credential leakage');
let old_id = keys[0].id;
config.outbounds[3].uuid = 'rotated';
check(canonical(map(discover(config), (k) => k.id)) != canonical(map(keys, (k) => k.id)), 'key rotation splits history');
check(classify(200, {delay:123})[0] == 1, 'success');
check(classify(200, {delay:0})[0] == -1, 'zero delay invalid');
check(classify(200, {delay:'123'})[0] == -1, 'string delay invalid');
check(classify(503, {})[0] == 0 && classify(504, {})[0] == 0, 'explicit probe failure');
for (let code in [0, 401, 403, 404, 500]) check(classify(code, {})[0] == -1, 'control failure unknown');
let k = keys[0];
record(k, 1000, 0, null, 300);
record(k, 1300, 0, null, 300);
record(k, 1600, 0, null, 300);
check(k.consecutive_failures == 3, 'consecutive failures');
record(k, 1900, -1, null, 300);
record(k, 2200, 0, null, 300);
check(k.consecutive_failures == 1, 'unknown breaks failure streak');
record(k, 4000, 0, null, 300);
check(k.consecutive_failures == 1, 'missed intervals break streak');
record(k, 4300, 1, 120, 300);
check(k.consecutive_failures == 0 && k.last_success == 4300, 'recovery');
record(k, 2000, 0, null, 300);
check(k.samples[length(k.samples)-1][0] == 2000 && k.consecutive_failures == 1, 'backwards clock');
check(k.last_success == null, 'backwards clock clears future last success');
check(!config_loaded({generation:'pid1',fingerprint:'old'}, 'pid1', 'new'), 'pending replacement unknown');
check(config_loaded({generation:'pid1',fingerprint:'old'}, 'pid2', 'new'), 'replacement allowed on runtime restart');
check(config_loaded({generation:'pid1',fingerprint:'same'}, 'pid1', 'same'), 'stable config accepted');
check(!config_loaded(null, null, 'new'), 'missing process is unknown');
let state = {keys: [k, {active:false, samples:[[1, 0, null]]}]};
trim_history(state, 100000, 1, 300);
check(length(state.keys) == 1 && length(k.samples) == 0, 'age retention and old archives');
k.samples = map([1,2,3,4,5], (v) => [99990+v, 1, v]);
trim_history(state, 100000, 1, 86400);
check(length(k.samples) == 3, 'count retention bound');
printf('PASS %d core assertions\n', count);
