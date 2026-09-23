// SPDX-License-Identifier: MIT
'use strict';
import { popen } from 'fs';

return {
	'luci.outbound-monitor': {
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
