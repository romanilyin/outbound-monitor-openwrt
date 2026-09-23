// SPDX-License-Identifier: MIT
'use strict';
import { popen } from 'fs';

function update_status() {
	let p = popen('/usr/bin/outbound-monitor-update status', 'r');
	let data = p ? p.read('all') : '';
	let code = p ? p.close() : -1;
	try { if (code == 0) return json(data); } catch(e) {}
	return {current: null, latest: null, available: false, running: false, stage: 'failed', error: 'Cannot read updater status'};
}
function start_update(action) {
	let s = update_status();
	if (s.running) return s;
	let result = system("( trap '' HUP; /usr/bin/outbound-monitor-update " + action + ' ) </dev/null >/dev/null 2>&1 &');
	if (result != 0) { s.error = 'Cannot start updater'; return s; }
	s.running = true;
	s.error = null;
	s.stage = action == 'check' ? 'checking' : 'updating';
	return s;
}

return {
	'luci.outbound-monitor': {
		update_status: { args: {}, call: function() { return update_status(); } },
		check_update: { args: {}, call: function() { return start_update('check'); } },
		update: { args: {}, call: function() { return start_update('install'); } },
		status: {
			args: { hours: 24 },
			call: function(request) {
				let h = int(request.args.hours);
				if (h != h || h < 1 || h > 168) h = 24;
				let p = popen('/usr/bin/outbound-monitor status ' + h, 'r');
				let data = p ? p.read('all') : '';
				let code = p ? p.close() : -1;
				try {
					if (code == 0) return json(data);
				} catch (e) {}
				return {version: 1, keys: [], now: time(), collector_error: 'Unable to read monitor status'};
			}
		}
	}
};
