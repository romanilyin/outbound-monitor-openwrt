import { section_targets } from '../outbound-monitor/files/usr/share/outbound-monitor/podkop.uc';
import { vpn_link_hash, canonical } from '../outbound-monitor/files/usr/share/outbound-monitor/core.uc';
let count = 0;
function check(ok, message) { if (!ok) die('FAIL podkop: ' + message + '\n'); count++; }
let a = 'vless://fake-secret-a@example.test:443#Label';
let b = 'hysteria2://fake-secret-b@example.test:443';
let targets = section_targets([
	{'.name':'single',connection_type:'proxy',proxy_config_type:'url',proxy_string:a},
	{'.name':'legacy',proxy_string:a},
	{'.name':'select',connection_type:'proxy',proxy_config_type:'selector',selector_proxy_links:[b,a]},
	{'.name':'test',connection_type:'proxy',proxy_config_type:'urltest',urltest_proxy_links:[a,b]},
	{'.name':'scalar',connection_type:'proxy',proxy_config_type:'urltest',urltest_proxy_links:b},
	{'.name':'warp',connection_type:'vpn',interface:'awg0'},
	{'.name':'exclude',connection_type:'exclusion',interface:'wan',proxy_string:a},
	{'.name':'block',connection_type:'block',proxy_string:a},
	{'.name':'empty',connection_type:'vpn',interface:''},
	{'.name':'custom',connection_type:'proxy',proxy_config_type:'outbound',outbound_json:'fake-secret-json'},
	{connection_type:'proxy',proxy_string:a}
]);
check(targets.links['single-out'] == vpn_link_hash(a), 'single URL maps to section-out');
check(targets.links['legacy-out'] == vpn_link_hash(a), 'legacy default URL mode');
check(targets.links['select-1-out'] == vpn_link_hash(b) && targets.links['select-2-out'] == vpn_link_hash(a), 'selector preserves positions');
check(targets.links['test-1-out'] == vpn_link_hash(a) && targets.links['test-2-out'] == vpn_link_hash(b), 'URLTest preserves positions');
check(targets.links['scalar-1-out'] == vpn_link_hash(b), 'single scalar list accepted');
check(canonical(targets.interfaces) == '{"warp-out":"awg0"}', 'only VPN sections permit interface outbounds');
check(length(keys(targets.links)) == 7, 'non-proxy and empty sections excluded');
check(index(canonical(targets), 'fake-secret') == -1 && index(canonical(targets), '://') == -1, 'raw credentials omitted');
check(canonical(section_targets([])) == '{"interfaces":{},"links":{}}', 'empty config');
printf('PASS %d podkop assertions\n', count);
