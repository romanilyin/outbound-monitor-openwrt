// Run from the repository with ucode tests/core.uc. No network or config changes.
import { canonical, discover, bind_keys, record, trim_history, classify, encode_path, config_loaded, vpn_link_hash } from '../outbound-monitor/files/usr/share/outbound-monitor/core.uc';
import { sha256 } from 'digest';
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
config.outbounds[3].uuid = 'rotated';
check(canonical(map(discover(config), (k) => k.id)) != canonical(map(keys, (k) => k.id)), 'key rotation splits history');
function clone(value) { return json(sprintf('%J', value)); }
function vpn_config(connections) {
	let outbounds = [{type:'urltest', tag:'vpn', outbounds:[]}];
	for (let i = 0; i < length(connections); i++) {
		let o = clone(connections[i]);
		o.tag = 'vpn-' + (i + 1) + '-out';
		push(outbounds[0].outbounds, o.tag);
		push(outbounds, o);
	}
	return {outbounds};
}
let link_a = 'vless://fake-secret-a@alpha.example:443?security=tls';
let link_b = 'vless://fake-secret-b@beta.example:443?security=tls';
let link_c = 'vless://fake-secret-c@beta.example:443?security=tls';
let hash_a = vpn_link_hash(link_a), hash_b = vpn_link_hash(link_b), hash_c = vpn_link_hash(link_c);
check(hash_a == sha256(link_a), 'link identity is the SHA-256 of the connection link');
check(vpn_link_hash('  ' + link_a + '#first label  ') == hash_a &&
	vpn_link_hash(link_a + '#renamed') == hash_a, 'whitespace and fragments do not change link identity');
check(vpn_link_hash('  #label') == null && vpn_link_hash(null) == null, 'empty link has no identity');
let conn_a = {type:'vless', server:'alpha.example', server_port:443, uuid:'fake-secret-a'};
let conn_b = {type:'vless', server:'beta.example', server_port:443, uuid:'fake-secret-b'};
let conn_c = {type:'vless', server:'beta.example', server_port:443, uuid:'fake-secret-c'};
let id_a = sha256(canonical(conn_a)), id_b = sha256(canonical(conn_b)), id_c = sha256(canonical(conn_c));
let first = vpn_config([conn_a, conn_b]);
let first_map = {'vpn-1-out':hash_a, 'vpn-2-out':hash_b};
let history = discover(first, first_map);
for (let key in history) for (let timestamp in [1000, 1300, 1600]) record(key, timestamp, 1, 123, 300);
let original_samples = canonical(history[0].samples);
let reordered = vpn_config([conn_b, conn_a]);
let reordered_map = {'vpn-1-out':hash_b, 'vpn-2-out':hash_a};
for (let key in history) { key.label = 'stale'; key.type = 'stale'; key.server = 'stale'; key.groups = ['stale']; }
history = bind_keys(history, discover(reordered, reordered_map), reordered);
let a = filter(history, (key) => key.id == id_a)[0];
let b = filter(history, (key) => key.id == id_b)[0];
check(a.tag == 'vpn-2-out' && b.tag == 'vpn-1-out', 'reordering rebinds both current API aliases');
check(a.label == a.tag && a.type == 'vless' && a.server == 'alpha.example:443' &&
	canonical(a.groups) == '["vpn"]', 'rebind refreshes all displayed metadata');
check(canonical(a.samples) == original_samples && canonical(b.samples) == original_samples,
	'reordering preserves three samples for each link');
check(a.link_hash == hash_a && a.id == id_a && a.identity_source == 'outbound_config', 'stored link identity metadata');
let pending = discover(first, reordered_map);
check(filter(pending, (key) => key.tag == 'vpn-1-out')[0].id == id_a,
	'pending UCI reorder never changes credential identity before JSON apply');
let pending_history = bind_keys(clone(history), pending, first);
check(canonical(filter(pending_history, (key) => key.id == id_a)[0].samples) == original_samples,
	'pending links and a manual process restart cannot move samples to another credential');
let replaced = vpn_config([conn_c, conn_a]);
history = bind_keys(history, discover(replaced, {'vpn-1-out':hash_c, 'vpn-2-out':hash_a}), replaced);
a = filter(history, (key) => key.id == id_a)[0];
b = filter(history, (key) => key.id == id_b)[0];
let c = filter(history, (key) => key.id == id_c)[0];
check(a.active && canonical(a.samples) == original_samples, 'replacing only B preserves A history');
check(!b.active && canonical(b.samples) == original_samples && c.active && length(c.samples) == 0,
	'replaced B is archived and replacement begins fresh history');
check(index(canonical(history), 'fake-secret') == -1 && index(canonical(history), 'vless://') == -1,
	'raw VPN links and credentials never enter key state');
let duplicate_config = vpn_config([conn_a, conn_a]);
push(duplicate_config.outbounds, {type:'urltest', tag:'second', outbounds:['vpn-1-out','vpn-2-out']});
let duplicates = discover(duplicate_config, {'vpn-1-out':hash_a, 'vpn-2-out':hash_a});
check(length(duplicates) == 1 && length(duplicates[0].tags) == 2 &&
	length(duplicates[0].groups) == 2 && duplicates[0].tag == 'vpn-1-out',
	'duplicate links merge aliases and groups and choose one current alias');
check(length(discover(duplicate_config)) == 1, 'duplicate generic connections ignore top-level tags');
let generic = vpn_config([conn_a]);
let generic_id = discover(generic)[0].id;
generic.outbounds[0].outbounds = ['renamed']; generic.outbounds[1].tag = 'renamed';
check(discover(generic)[0].id == generic_id && discover(generic)[0].link_hash == null,
	'generic connection identity survives tag rename without claiming a link hash');
generic.outbounds[1].uuid = 'replacement';
check(discover(generic)[0].id != generic_id, 'generic credential replacement changes identity');
let legacy = discover(first);
for (let key in legacy) {
	let o = filter(first.outbounds, (outbound) => outbound.tag == key.tag)[0];
	key.id = sha256(canonical(o));
	delete key.identity_source; delete key.link_hash; delete key.tags;
	for (let timestamp in [1000,1300,1600]) record(key, timestamp, 1, 123, 300);
}
legacy = bind_keys(legacy, discover(reordered, reordered_map), reordered);
check(length(legacy) == 2 && length(filter(legacy, (key) => key.active)) == 2 &&
	filter(legacy, (key) => key.id == id_a)[0].tag == 'vpn-2-out' &&
	canonical(legacy[0].samples) == original_samples, 'legacy tagged identities migrate by full credential hash');
let wrong_legacy = clone(legacy[0]);
wrong_legacy.id = sha256(canonical({type:'vless', tag:wrong_legacy.tag, server:'alpha.example',
	server_port:443, uuid:'unrelated-credential'}));
delete wrong_legacy.identity_source;
let protected_history = bind_keys([wrong_legacy], discover(vpn_config([conn_a]), {'vpn-1-out':hash_a}), vpn_config([conn_a]));
check(length(protected_history) == 2 && !protected_history[0].active &&
	length(protected_history[1].samples) == 0, 'legacy history never merges merely by matching server');
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
record(k, 2500, -2, null, 300);
check(k.current == -2 && k.samples[length(k.samples)-1][1] == -2 && k.consecutive_failures == 0,
	'external network failure is retained without a VPN failure streak');
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
check(config_loaded({generation:'pid1',fingerprint:'same'}, 'pid1', 'same', 'links'), 'legacy runtime accepts first link baseline');
check(!config_loaded({generation:'pid1',fingerprint:'same',link_fingerprint:'old'}, 'pid1', 'same', 'new'),
	'changed links wait for apply even when JSON has not changed');
check(config_loaded({generation:'pid1',fingerprint:'same',link_fingerprint:'old'}, 'pid2', 'same', 'new'),
	'new process accepts changed link mapping');
check(config_loaded({generation:'pid1',fingerprint:'same',link_fingerprint:'links'}, 'pid1', 'same', 'links'),
	'unchanged configuration and links accepted');
check(!config_loaded(null, null, 'new'), 'missing process is unknown');
let state = {keys: [k, {active:false, samples:[[1, 0, null]]}]};
trim_history(state, 100000, 1, 300);
check(length(state.keys) == 1 && length(k.samples) == 0, 'age retention and old archives');
k.samples = map([1,2,3,4,5], (v) => [99990+v, 1, v]);
trim_history(state, 100000, 1, 86400);
check(length(k.samples) == 3, 'count retention bound');
printf('PASS %d core assertions\n', count);
