'use strict';
'require view';
'require rpc';
'require poll';

var callStatus = rpc.declare({ object: 'luci.outbound-monitor', method: 'status', params: [ 'hours' ], expect: {} });
var callUpdateStatus = rpc.declare({ object: 'luci.outbound-monitor', method: 'update_status', expect: {} });
var callCheckUpdate = rpc.declare({ object: 'luci.outbound-monitor', method: 'check_update', expect: {} });
var callUpdate = rpc.declare({ object: 'luci.outbound-monitor', method: 'update', expect: {} });
var ranges = [ [ 1, _('1 hour') ], [ 6, _('6 hours') ], [ 24, _('24 hours') ], [ 168, _('7 days') ] ];

function userLocale() {
	return typeof document !== 'undefined' && document.documentElement ? document.documentElement.lang || undefined : undefined;
}

function finite(value) {
	return typeof value === 'number' && isFinite(value);
}

function dateTime(epoch) {
	return finite(epoch) && epoch > 0 ? new Date(epoch * 1000).toLocaleString(userLocale()) : _('no data');
}

function number(value) {
	return finite(value) ? value.toLocaleString(userLocale(), { maximumFractionDigits: 1 }) : '—';
}

function percentage(value) {
	if (!finite(value))
		return '—';
	return (value < 100 && value > 99.99 ? '>' + (99.99).toLocaleString(userLocale()) : value.toLocaleString(userLocale(), { maximumFractionDigits: 2 })) + '%';
}

function rangeLabel(hours) {
	return ranges.filter(function(item) { return item[0] === hours; })[0][1];
}

function samplesInRange(samples, from, to) {
	var byTime = Object.create(null);
	(Array.isArray(samples) ? samples : []).forEach(function(sample) {
		if (!Array.isArray(sample) || !finite(sample[0]) || sample[0] < from || sample[0] > to)
			return;
		var status = sample[1] === 1 || sample[1] === 0 || sample[1] === -2 ? sample[1] : -1;
		var delay = status === 1 && finite(sample[2]) && sample[2] >= 0 ? sample[2] : null;
		if (status === 1 && delay === null)
			status = -1;
		byTime[sample[0]] = [ sample[0], status, delay ];
	});
	return Object.keys(byTime).map(function(time) { return byTime[time]; }).sort(function(a, b) { return a[0] - b[0]; });
}

function statistics(samples, interval) {
	var result = { success: 0, failed: 0, unknown: 0, upstream: 0, missing: 0, median: null, availability: null, failurePercent: null, mean: null, variance: null, stddev: null };
	var delays = [];
	samples.forEach(function(sample, index) {
		if (sample[1] === 1) {
			result.success++;
			delays.push(sample[2]);
		}
		else if (sample[1] === 0)
			result.failed++;
		else if (sample[1] === -2)
			result.upstream++;
		else
			result.unknown++;
		if (index && sample[0] - samples[index - 1][0] > interval * 1.8)
			result.missing += Math.max(1, Math.round((sample[0] - samples[index - 1][0]) / interval) - 1);
	});
	var measured = result.success + result.failed;
	if (measured) {
		result.availability = result.success * 100 / measured;
		result.failurePercent = result.failed * 100 / measured;
	}
	if (delays.length) {
		delays.sort(function(a, b) { return a - b; });
		var middle = Math.floor(delays.length / 2);
		result.median = delays.length % 2 ? delays[middle] : delays[middle - 1] / 2 + delays[middle] / 2;
		// Welford on power-of-two scaled values avoids overflowing intermediate sums.
		var maximum = delays[delays.length - 1];
		var scale = maximum > 0 ? Math.pow(2, Math.max(-1022, Math.min(1023, Math.floor(Math.log(maximum) / Math.LN2)))) : 1;
		var mean = 0, m2 = 0;
		delays.forEach(function(delay, index) {
			var value = delay / scale;
			var delta = value - mean;
			mean += delta / (index + 1);
			m2 += delta * (value - mean);
		});
		result.mean = mean * scale;
		result.stddev = Math.sqrt(Math.max(0, m2 / delays.length)) * scale;
		var variance = result.stddev * result.stddev;
		result.variance = finite(variance) ? variance : null;
	}
	return result;
}

function comparisonRows(data, now, hours, unavailable) {
	var interval = data.interval > 0 ? data.interval : 300;
	function compareNumber(a, b) {
		return a === null ? b === null ? 0 : 1 : b === null ? -1 : a - b;
	}
	return data.keys.filter(function(key) { return key.active !== false; }).map(function(key) {
		return { key: key, stats: statistics(samplesInRange(key.samples, now - hours * 3600, now), interval), state: keyState(key, now, interval, unavailable) };
	}).sort(function(a, b) {
		return compareNumber(a.stats.failurePercent, b.stats.failurePercent) || compareNumber(a.stats.mean, b.stats.mean) || String(a.key.label || a.key.tag || a.key.id).localeCompare(String(b.key.label || b.key.tag || b.key.id)) || String(a.key.id).localeCompare(String(b.key.id));
	});
}

function renderComparison(data, now, hours, unavailable) {
	var columns = [ _('Key'), _('VPN failure rate'), _('Mean HTTP delay'), _('Population variance') ];
	var rows = comparisonRows(data, now, hours, unavailable).map(function(row) {
		var key = row.key, stats = row.stats;
		return E('tr', {}, [
			E('th', { scope: 'row', 'class': 'om-comparison-key' }, [
				E('strong', {}, key.label || key.tag || _('Unnamed')),
				key.label && key.tag && key.label !== key.tag ? E('small', { 'class': 'om-muted' }, key.tag) : '',
				E('span', { 'class': 'om-badge om-' + row.state.kind, title: _('Last probe: %s').format(dateTime(key.last_checked)) }, row.state.label),
				E('small', { 'class': 'om-muted' }, _('Known probes: %s · successful: %s').format(stats.success + stats.failed, stats.success)),
				E('small', { 'class': 'om-muted' }, _('Unknown: %s · missing: ≈%s').format(stats.unknown, stats.missing)),
				stats.upstream ? E('small', { 'class': 'om-upstream-text' }, _('External failures: %s').format(stats.upstream)) : ''
			]),
			E('td', { 'data-label': columns[1] }, E('strong', {}, percentage(stats.failurePercent))),
			E('td', { 'data-label': columns[2] }, E('strong', {}, stats.mean === null ? '—' : _('%s ms').format(number(stats.mean)))),
			E('td', { 'data-label': columns[3] }, [
				E('strong', {}, stats.variance === null ? '—' : _('%s ms²').format(number(stats.variance))),
				E('small', { 'class': 'om-muted', title: _('Standard deviation') }, _('SD: %s ms').format(number(stats.stddev)))
			])
		]);
	});
	return E('section', { 'class': 'om-comparison' }, [
		E('h3', {}, _('Active outbounds · %s').format(rangeLabel(hours))),
		rows.length ? E('table', {}, [ E('thead', {}, E('tr', {}, columns.map(function(label) { return E('th', { scope: 'col' }, label); }))), E('tbody', {}, rows) ]) : E('p', { 'class': 'om-muted' }, _('No active outbounds.')),
		E('p', { 'class': 'om-footnote' }, _('VPN failure rate = VPN failures / (successes + VPN failures). Mean, population variance and SD use successes only. Unknown, missing and suspected external failures are excluded. One success gives zero variance.')),
		E('p', { 'class': 'om-footnote' }, _('Sorted by failure rate, then mean delay. These are historical figures; compare sample counts and freshness before choosing a key.'))
	]);
}

function keyState(key, now, interval, unavailable) {
	if (key.active === false)
		return { kind: 'archive', label: _('Archived key'), replace: false };
	if (unavailable)
		return { kind: 'unknown', label: _('No fresh response'), replace: false };
	if (!finite(key.last_checked) || key.last_checked <= 0)
		return { kind: 'unknown', label: _('Not checked yet'), replace: false };
	if (now - key.last_checked > interval * 2 || key.last_checked > now + interval)
		return { kind: 'unknown', label: _('Stale data'), replace: false };
	if (key.current === 1)
		return { kind: 'ok', label: _('Probe succeeded'), replace: false };
	if (key.current === 0)
		return { kind: 'failed', label: _('Probe failed'), replace: key.consecutive_failures >= 3 };
	if (key.current === -2)
		return { kind: 'upstream', label: _('External network failure'), replace: false };
	return { kind: 'unknown', label: _('Unknown result'), replace: false };
}

function chartGeometry(samples, from, to, interval) {
	var maximum = samples.reduce(function(value, sample) { return sample[1] === 1 ? Math.max(value, sample[2]) : value; }, 0);
	var top = Math.max(10, maximum);
	var unit = Math.pow(10, Math.floor(Math.log(top) / Math.LN10));
	var rounded = Math.ceil(top / unit) * unit;
	top = finite(rounded) ? rounded : top;
	var geometry = { left: 112, right: 766, top: 28, zero: 178, failure: 208, bottom: 252, maximum: top, paths: [], points: [] };
	geometry.x = function(time) { return geometry.left + (time - from) / Math.max(1, to - from) * (geometry.right - geometry.left); };
	geometry.y = function(delay) { return delay === -10 ? geometry.failure : geometry.zero - delay / top * (geometry.zero - geometry.top); };
	var path = [];
	samples.forEach(function(sample, index) {
		var previous = samples[index - 1];
		if (sample[1] !== 1 || previous && (previous[1] !== 1 || sample[0] - previous[0] > interval * 1.8)) {
			if (path.length)
				geometry.paths.push(path);
			path = [];
		}
		if (sample[1] !== -1) {
			var point = { x: geometry.x(sample[0]), y: geometry.y(sample[1] === 1 ? sample[2] : -10), sample: sample };
			geometry.points.push(point);
			if (sample[1] === 1)
				path.push(point);
		}
	});
	if (path.length)
		geometry.paths.push(path);
	return geometry;
}

function tickLabel(value) {
	return value >= 100000 ? value.toExponential(1) : number(value);
}

function sampleLabel(sample) {
	return dateTime(sample[0]) + ' · ' + (sample[1] === 1 ? _('%s ms').format(number(sample[2])) : sample[1] === 0 ? _('probe failed (−10)') : sample[1] === -2 ? _('external network failure suspected (−10)') : _('no result'));
}

function svgNode(tag, attributes, children) {
	var node = document.createElementNS('http://www.w3.org/2000/svg', tag);
	Object.keys(attributes || {}).forEach(function(name) { node.setAttribute(name, attributes[name]); });
	(children || []).forEach(function(child) { node.appendChild(typeof child === 'string' ? document.createTextNode(child) : child); });
	return node;
}

function renderChart(samples, from, to, interval, label) {
	var g = chartGeometry(samples, from, to, interval);
	var chart = svgNode('svg', { viewBox: '0 0 800 252', role: 'img', 'aria-label': _('%s: HTTP delay in milliseconds').format(label) }, [
		svgNode('title', {}, [ _('%s — HTTP delay, ms. Failures are at −10; unknown and missing probes break the line.').format(label) ]),
		svgNode('text', { x: g.left, y: 15, 'class': 'om-axis-title' }, [ _('HTTP, ms') ]),
		svgNode('rect', { x: g.left, y: 194, width: g.right - g.left, height: 28, 'class': 'om-error-band' })
	]);
	[ 0, g.maximum / 2, g.maximum ].forEach(function(value) {
		var y = g.y(value);
		chart.appendChild(svgNode('line', { x1: g.left, x2: g.right, y1: y, y2: y, 'class': 'om-grid' }));
		chart.appendChild(svgNode('text', { x: g.left - 12, y: y + 4, 'text-anchor': 'end', 'class': 'om-axis' }, [ tickLabel(value) ]));
	});
	chart.appendChild(svgNode('text', { x: g.left - 12, y: g.failure + 4, 'text-anchor': 'end', 'class': 'om-axis om-error-label' }, [ '−10' ]));
	chart.appendChild(svgNode('path', { d: 'M ' + (g.left - 8) + ' 186 l 5 -3 m -5 7 l 5 -3', 'class': 'om-axis-break' }));
	[ 0, 0.5, 1 ].forEach(function(fraction) {
		var time = from + fraction * (to - from);
		var date = new Date(time * 1000);
		var text = date.toLocaleTimeString(userLocale(), { hour: '2-digit', minute: '2-digit' });
		if (to - from >= 86400)
			text = date.toLocaleDateString(userLocale(), { day: '2-digit', month: '2-digit' }) + ' ' + text;
		chart.appendChild(svgNode('text', { x: g.x(time), y: 245, 'text-anchor': fraction === 0 ? 'start' : fraction === 1 ? 'end' : 'middle', 'class': 'om-axis' }, [ text ]));
	});
	g.paths.forEach(function(path) {
		if (path.length > 1)
			chart.appendChild(svgNode('polyline', { points: path.map(function(point) { return point.x + ',' + point.y; }).join(' '), 'class': 'om-trace' }));
	});
	g.points.forEach(function(point) {
		chart.appendChild(svgNode('circle', { cx: point.x, cy: point.y, r: point.sample[1] === 1 ? 3.6 : 4.5, 'class': point.sample[1] === 0 ? 'om-failed-point' : point.sample[1] === -2 ? 'om-upstream-point' : 'om-ok-point' }, [ svgNode('title', {}, [ sampleLabel(point.sample) ]) ]));
	});
	var cursor = svgNode('line', { x1: 0, x2: 0, y1: g.top, y2: 222, 'class': 'om-cursor', visibility: 'hidden' });
	chart.appendChild(cursor);
	var hint = E('div', { 'class': 'om-chart-hint', 'aria-live': 'polite' }, [ samples.length ? _('Hover over or touch the chart to inspect a probe.') : _('No probes in the selected period yet.') ]);
	var index = samples.length - 1;
	function showSample(sample) {
		cursor.setAttribute('x1', g.x(sample[0]));
		cursor.setAttribute('x2', g.x(sample[0]));
		cursor.setAttribute('visibility', 'visible');
		hint.textContent = sampleLabel(sample);
	}
	chart.setAttribute('tabindex', samples.length ? '0' : '-1');
	chart.setAttribute('aria-description', _('Use the left and right arrow keys to select a probe.'));
	function inspectPointer(event) {
		if (!samples.length)
			return;
		var bounds = chart.getBoundingClientRect();
		var x = (event.clientX - bounds.left) / bounds.width * 800;
		var target = from + (x - g.left) / (g.right - g.left) * (to - from);
		var nearest = samples.reduce(function(best, sample, i) { return Math.abs(sample[0] - target) < Math.abs(samples[best][0] - target) ? i : best; }, 0);
		index = nearest;
		showSample(samples[index]);
	}
	chart.addEventListener('pointermove', inspectPointer);
	chart.addEventListener('pointerdown', inspectPointer);
	chart.addEventListener('focus', function() { if (samples.length) showSample(samples[index]); });
	chart.addEventListener('keydown', function(event) {
		if (!samples.length || event.key !== 'ArrowLeft' && event.key !== 'ArrowRight')
			return;
		event.preventDefault();
		index = Math.max(0, Math.min(samples.length - 1, index + (event.key === 'ArrowLeft' ? -1 : 1)));
		showSample(samples[index]);
	});
	return E('div', { 'class': 'om-chart' }, [ E('div', { 'class': 'om-chart-scroll' }, [ chart ]), hint ]);
}

function metric(label, value, detail) {
	return E('div', { 'class': 'om-metric' }, [ E('span', {}, label), E('strong', {}, value), E('small', {}, detail) ]);
}

function renderKey(key, data, now, hours, unavailable) {
	var interval = data.interval > 0 ? data.interval : 300;
	var samples = samplesInRange(key.samples, now - hours * 3600, now);
	var stats = statistics(samples, interval);
	var state = keyState(key, now, interval, unavailable);
	var label = key.label || key.tag || _('Unnamed');
	var measured = stats.success + stats.failed;
	return E('section', { 'class': 'om-card' + (key.active === false ? ' om-archived' : '') }, [
		E('div', { 'class': 'om-card-heading' }, [
			E('div', {}, [ E('h3', {}, label), E('div', { 'class': 'om-muted om-key-details' }, [ (key.type || 'outbound') + ' · ' + (key.server || _('unknown server')) ]), E('code', { 'class': 'om-fingerprint', title: key.id || '' }, 'ID ' + String(key.id || '—').slice(0, 12)) ]),
			E('span', { 'class': 'om-badge om-' + state.kind }, state.label)
		]),
		Array.isArray(key.groups) && key.groups.length ? E('p', { 'class': 'om-groups om-muted' }, _('Groups: %s').format(key.groups.join(', '))) : '',
		key.active === false ? E('p', { 'class': 'om-note' }, _('This key is no longer in the current configuration. Its history is retained below.')) : '',
		state.replace ? E('p', { 'class': 'om-advice' }, _('Consecutive failures: %s. Check the connection and consider replacing the key. Failures do not prove that the key has expired.').format(key.consecutive_failures)) : '',
		E('div', { 'class': 'om-metrics' }, [
			metric(_('Successful probes'), percentage(stats.availability), _('%s of %s known results').format(stats.success, measured)),
			metric(_('Median HTTP delay'), stats.median === null ? '—' : _('%s ms').format(number(stats.median)), _('successful probes in this period')),
			metric(_('VPN failures'), String(stats.failed), _('unknown results: %s').format(stats.unknown))
		]),
		renderChart(samples, now - hours * 3600, now, interval, label),
		stats.upstream ? E('p', { 'class': 'om-footnote om-upstream-text' }, _('Suspected external failures: %s. Excluded from VPN failure rate and delay statistics.').format(stats.upstream)) : '',
		E('p', { 'class': 'om-footnote' }, _('Probes: %s. Missing between probes: ≈%s. The percentage describes individual probes, not continuous uptime.').format(samples.length, stats.missing)),
		E('div', { 'class': 'om-times om-muted' }, [ E('span', {}, _('Last probe: %s').format(dateTime(key.last_checked))), E('span', {}, _('Last success: %s').format(dateTime(key.last_success))) ])
	]);
}

function csvCell(value) {
	var text = value == null ? '' : String(value);
	if (typeof value === 'string' && /^[=+\-@\t\r\n]/.test(text))
		text = "'" + text;
	return '"' + text.replace(/"/g, '""') + '"';
}

function csvData(data) {
	var rows = [ [ 'id', 'label', 'tag', 'type', 'server', 'groups', 'active', 'timestamp_utc', 'status', 'delay_ms' ] ];
	data.keys.forEach(function(key) {
		var prefix = [ key.id, key.label, key.tag, key.type, key.server, (key.groups || []).join(';'), key.active !== false ];
		var samples = Array.isArray(key.samples) ? key.samples : [];
		if (!samples.length)
			rows.push(prefix.concat([ '', '', '' ]));
		samples.forEach(function(sample) {
			rows.push(prefix.concat([ finite(sample[0]) ? new Date(sample[0] * 1000).toISOString() : '', sample[1], sample[1] === 1 ? sample[2] : '' ]));
		});
	});
	return '\uFEFF' + rows.map(function(row) { return row.map(csvCell).join(','); }).join('\r\n');
}

function validData(data) {
	if (!data || data.version !== 1 || !Array.isArray(data.keys) || !finite(data.now) || data.keys.some(function(key) { return !key || typeof key !== 'object'; }))
		throw new Error(_('The monitor returned invalid data'));
	return data;
}

function validUpdater(data) {
	if (!data || typeof data.current !== 'string' || typeof data.available !== 'boolean' || typeof data.running !== 'boolean' || [ 'idle', 'checking', 'updating', 'done', 'failed' ].indexOf(data.stage) < 0)
		throw new Error(_('The updater returned invalid data'));
	return data;
}

function diagnosticLabel(status) {
	var labels = { ok: _('OK'), issues: _('Issues detected'), error: _('Error'), mismatch: _('Mismatch'), warning: _('Warning'), partial: _('Partial result'), failed: _('Failed'), timeout: _('Timed out'), unavailable: _('Unavailable'), blocked: _('Blocked'), disabled: _('Disabled'), not_installed: _('IPRegion is not installed'), not_run: _('Not run'), not_tested: _('Not tested') };
	return labels[status] || String(status || '—');
}

function dnsSummary(dns) {
	if (!dns)
		return '—';
	if (!dns.summary || !dns.checked_at)
		return diagnosticLabel(dns.status);
	return diagnosticLabel(dns.status) + ' · ' + _('OK: %s · mismatch: %s · warning: %s · failed: %s').format(number(dns.summary.ok), number(dns.summary.mismatch), number(dns.summary.warning), number(dns.summary.failed));
}

function connectivityLabel(connectivity) {
	if (!connectivity)
		return '—';
	if (connectivity.reason === 'mixed')
		return _('Direct failed; VPN available');
	return connectivity.status === 1 ? _('Direct checks passed') : connectivity.status === 0 ? _('Direct checks failed') : _('Unknown result');
}

function renderDiagnostics(data) {
	var dns = data.dns;
	var nodes = [];
	if (data.dns_enabled === false || dns && dns.status === 'disabled')
		nodes.push(E('p', { 'class': 'om-footnote' }, _('DNS diagnostics are disabled.')));
	else if (data.dns_available === false || dns && dns.status === 'not_installed')
		nodes.push(E('p', { 'class': 'om-footnote' }, _('Optional DNS diagnostics require IPRegion.')));
	else if (dns && dns.status === 'not_run')
		nodes.push(E('p', { 'class': 'om-footnote' }, _('DNS diagnostics have not run yet. They run after both direct checks fail.')));
	if (dns && finite(dns.checked_at) && dns.checked_at > 0) {
		var details = [
			E('summary', {}, _('DNS diagnostics · %s').format(dateTime(dns.checked_at))),
			E('p', { 'class': 'om-muted' }, dnsSummary(dns)),
			E('p', { 'class': 'om-footnote' }, _('Encrypted DNS is tested through the router route, which may include a VPN. These results do not prove an ISP failure or DNS tampering.'))
		];
		if (Array.isArray(dns.resolvers) && dns.resolvers.length) {
			var transports = dns.resolvers.some(function(resolver) { return resolver.udp != null || resolver.tcp != null; }) ? [ 'udp', 'tcp', 'dot', 'doh' ] : [ 'dot', 'doh' ];
			var transportNames = { udp: 'UDP', tcp: 'TCP', dot: 'DoT', doh: 'DoH' };
			details.push(E('table', { 'class': 'om-diagnostic-table' }, [
				E('thead', {}, E('tr', {}, [ E('th', { scope: 'col' }, _('Resolver')), E('th', { scope: 'col' }, _('Result')) ].concat(transports.map(function(transport) { return E('th', { scope: 'col' }, transportNames[transport]); })))),
				E('tbody', {}, dns.resolvers.map(function(resolver) {
					var name = resolver.name || resolver.id || '—';
					if (resolver.ip_version === 4 || resolver.ip_version === 6)
						name += ' · IPv' + resolver.ip_version;
					return E('tr', {}, [ E('th', { scope: 'row' }, name), E('td', {}, diagnosticLabel(resolver.status)) ].concat(transports.map(function(transport) { return E('td', {}, diagnosticLabel(resolver[transport])); })));
				}))
			]));
		}
		if (dns.error)
			details.push(E('p', { 'class': 'om-alert' }, String(dns.error)));
		nodes.push(E('details', { 'class': 'om-diagnostics' }, details));
	}
	var events = (Array.isArray(data.network_events) ? data.network_events : []).filter(function(event) { return event && finite(event.checked_at); }).sort(function(a, b) { return b.checked_at - a.checked_at; });
	if (events.length)
		nodes.push(E('details', { 'class': 'om-diagnostics' }, [
			E('summary', {}, _('Recorded network incidents · %s').format(events.length)),
			E('p', { 'class': 'om-footnote' }, _('The latest 20 incidents are shown. JSON export includes all received events.')),
			E('table', { 'class': 'om-diagnostic-table om-event-table' }, [
				E('thead', {}, E('tr', {}, [ E('th', { scope: 'col' }, _('Time')), E('th', { scope: 'col' }, _('Connectivity')), E('th', { scope: 'col' }, _('DNS diagnostics')) ])),
				E('tbody', {}, events.slice(0, 20).map(function(event) { return E('tr', {}, [ E('td', {}, dateTime(event.checked_at)), E('td', {}, connectivityLabel(event.connectivity)), E('td', {}, dnsSummary(event.dns)) ]); }))
			])
		]));
	return nodes.length ? E('div', { 'class': 'om-diagnostics-area' }, nodes) : null;
}

return view.extend({
	hours: 24,
	dataHours: 24,
	requestId: 0,
	load: function() {
		return Promise.all([
			callStatus(24).then(function(data) { return { data: validData(data) }; }).catch(function(error) { return { error: error.message || String(error) }; }),
			callUpdateStatus().then(function(data) { return { updater: validUpdater(data) }; }).catch(function(error) { return { updaterError: error.message || String(error) }; })
		]).then(function(results) { return Object.assign(results[0], results[1]); });
	},
	render: function(result) {
		this.data = result.data || null;
		this.error = result.error || null;
		this.updater = result.updater || null;
		this.updaterError = result.updaterError || null;
		this.receivedAt = Date.now();
		this.lastHistoryPoll = this.lastUpdaterPoll = Date.now();
		var self = this;
		var selector = E('select', { 'aria-label': _('History period'), change: function(event) { self.hours = Number(event.target.value); self.refresh(); } }, ranges.map(function(item) {
			return E('option', { value: item[0], selected: item[0] === self.hours ? '' : null }, item[1]);
		}));
		this.exportJson = E('button', { 'class': 'cbi-button', click: function() { self.download('json'); } }, 'JSON');
		this.exportCsv = E('button', { 'class': 'cbi-button', click: function() { self.download('csv'); } }, 'CSV');
		this.statusNode = E('div', { 'class': 'om-status', 'aria-live': 'polite' });
		this.contentNode = E('div');
		this.updaterNode = E('section', { 'class': 'om-updater', 'aria-live': 'polite' });
		var root = E('div', { 'class': 'om-page' }, [
			E('link', { rel: 'stylesheet', href: L.resource('outbound-monitor/style.css') }),
			E('div', { 'class': 'om-header' }, [ E('div', {}, [ E('h2', {}, _('Outbound Monitor')), E('p', { 'class': 'om-muted' }, _('HTTP probe history for each key')) ]), E('div', { 'class': 'om-controls' }, [ E('label', {}, [ _('Period'), ' ', selector ]), E('span', { 'class': 'om-export-label' }, _('Export:')), this.exportJson, this.exportCsv ]) ]),
			this.updaterNode,
			this.statusNode,
			E('div', { 'class': 'om-legend' }, [ E('span', { 'class': 'om-legend-success' }, '● ' + _('HTTP delay, ms')), E('span', { 'class': 'om-legend-failure' }, '● ' + _('VPN failure: −10')), E('span', { 'class': 'om-upstream-text' }, '● ' + _('Suspected external failure: −10')), E('span', {}, _('Gaps mean unknown or missing probes')) ]),
			E('p', { 'class': 'om-footnote' }, _('The positive scale is linear; −10 uses a separate failure band. Times use the browser time zone. Exports contain the received data for the selected period.')),
			E('p', { 'class': 'om-footnote' }, _('Blue failures suggest an external network or ISP issue; the cause is not confirmed.')),
			this.contentNode
		]);
		this.paint();
		this.paintUpdater();
		poll.add(this.tick.bind(this), 5);
		return root;
	},
	tick: function() {
		var jobs = [];
		var now = Date.now();
		if (!this.loading && now - this.lastHistoryPoll >= 60000)
			jobs.push(this.refresh());
		if (!this.updaterPending && (this.updaterUncertain || this.updater && this.updater.running || now - this.lastUpdaterPoll >= 60000))
			jobs.push(this.refreshUpdater('status'));
		return Promise.all(jobs);
	},
	refreshUpdater: function(action) {
		if (this.updaterPending || action !== 'status' && (this.updaterUncertain || this.updater && this.updater.running))
			return Promise.resolve();
		if (action === 'install' && (!this.updater || !this.updater.available))
			return Promise.resolve();
		var self = this;
		var method = action === 'install' ? callUpdate : action === 'check' ? callCheckUpdate : callUpdateStatus;
		this.updaterPending = true;
		this.lastUpdaterPoll = Date.now();
		if (action !== 'status')
			this.updaterUncertain = true;
		this.paintUpdater();
		return method().then(function(data) {
			var next = validUpdater(data);
			if (next.stage === 'done' && !next.running && !next.error && (self.sawInstalling || self.updater && self.updater.current !== next.current || action === 'install'))
				self.reloadNeeded = true;
			self.sawInstalling = next.stage === 'updating';
			self.updater = next;
			self.updaterError = null;
			self.updaterUncertain = false;
		}).catch(function(error) {
			self.updaterError = error.message || String(error);
		}).then(function() {
			self.updaterPending = false;
			self.paintUpdater();
		});
	},
	paintUpdater: function() {
		var self = this;
		var state = this.updater;
		var busy = !!(this.updaterPending || this.updaterUncertain || state && state.running);
		var message = _('Check GitHub for the latest stable release.');
		if (state && state.stage === 'checking')
			message = _('Checking GitHub…');
		else if (state && state.stage === 'updating')
			message = _('Installing update… History remains visible while services restart.');
		else if (state && state.stage === 'failed')
			message = _('Update failed.');
		else if (this.reloadNeeded)
			message = _('Update installed. Reload this page to use the new interface.');
		else if (state && state.available)
			message = _('An update is available.');
		else if (state && state.latest)
			message = _('No newer stable release.');
		this.checkButton = E('button', { 'class': 'cbi-button', disabled: busy ? '' : null, click: function() { return self.refreshUpdater('check'); } }, _('Check for updates'));
		this.updateButton = E('button', { 'class': 'cbi-button cbi-button-action', disabled: busy || !state || !state.available ? '' : null, click: function() { return self.refreshUpdater('install'); } }, _('Update from GitHub'));
		var actions = [ this.checkButton, this.updateButton ];
		if (this.reloadNeeded)
			actions.push(E('button', { 'class': 'cbi-button', click: function() { window.location.reload(); } }, _('Reload page')));
		var nodes = [
			E('div', { 'class': 'om-updater-heading' }, [ E('strong', {}, _('Version and updates')), E('div', { 'class': 'om-controls' }, actions) ]),
			E('p', { 'class': 'om-muted om-meta' }, _('Installed: %s · Latest: %s · Last checked: %s').format(state ? state.current : _('unknown'), state && state.latest || '—', dateTime(state && state.checked_at))),
			E('p', { 'class': 'om-muted om-meta' }, message)
		];
		if (state && /^https:\/\/github\.com\/romanilyin\/outbound-monitor-openwrt\/releases\/tag\/\d{4}-\d{1,2}-\d{1,2}-\d+$/.test(state.release_url || ''))
			nodes.push(E('a', { href: state.release_url, target: '_blank', rel: 'noopener noreferrer', 'class': 'om-release-link' }, _('Release notes')));
		if (this.updaterError || state && state.error)
			nodes.push(E('p', { 'class': 'om-alert', role: 'alert' }, _('Updater: %s').format(this.updaterError || state.error)));
		if (this.updaterUncertain && !this.updaterPending)
			nodes.push(E('p', { 'class': 'om-muted om-meta' }, _('Waiting for the updater to reconnect. The action will not be sent again.')));
		this.updaterNode.replaceChildren.apply(this.updaterNode, nodes);
	},
	refresh: function() {
		var self = this;
		var hours = this.hours;
		var request = ++this.requestId;
		this.loading = true;
		this.lastHistoryPoll = Date.now();
		this.paintStatus();
		return callStatus(hours).then(function(data) {
			if (request !== self.requestId)
				return;
			self.data = validData(data);
			self.dataHours = hours;
			self.receivedAt = Date.now();
			self.error = null;
		}).catch(function(error) {
			if (request === self.requestId)
				self.error = error.message || String(error);
		}).then(function() {
			if (request === self.requestId) {
				self.loading = false;
				self.paint();
			}
		});
	},
	paintStatus: function() {
		var nodes = [];
		if (this.error)
			nodes.push(E('p', { 'class': 'om-alert', role: 'alert' }, _('Could not refresh the monitor: %s.').format(this.error) + ' ' + (this.data ? _('Showing previously received data for %s; the current status is unknown.').format(rangeLabel(this.dataHours)) : _('Check whether the collector is running.'))));
		if (this.data && this.data.collector_error)
			nodes.push(E('p', { 'class': 'om-alert', role: 'alert' }, _('Collector error: %s. The current key status is unknown.').format(this.data.collector_error)));
		if (this.loading)
			nodes.push(E('p', { 'class': 'om-muted' }, _('Refreshing data for %s…').format(rangeLabel(this.hours))));
		if (this.data) {
			var data = this.data;
			var connectivity = data.connectivity;
			var active = data.keys.filter(function(key) { return key.active !== false; });
			if (connectivity && connectivity.reason === 'direct_failed' && active.length && active.every(function(key) { return key.current === 0 || key.current === -2; }))
				nodes.push(E('p', { 'class': 'om-upstream-note' }, _('At %s, both direct checks and all VPN probes failed. An external network or ISP issue is possible.').format(dateTime(connectivity.checked_at))));
			else if (connectivity && connectivity.reason === 'mixed')
				nodes.push(E('p', { 'class': 'om-upstream-note' }, _('Direct checks failed while at least one VPN probe succeeded. Last check: %s.').format(dateTime(connectivity.checked_at))));
			var diagnostics = renderDiagnostics(data);
			if (diagnostics)
				nodes.push(diagnostics);
			nodes.push(E('p', { 'class': 'om-muted om-meta' }, _('History: %s · Probe interval: %s min · Collector: %s').format(rangeLabel(this.dataHours), number((data.interval || 300) / 60), dateTime(data.updated_at)) + ' · ' + (data.storage === 'ram' ? _('History is in RAM and is lost on reboot') : _('Storage: %s').format(data.storage || _('unknown')))));
			nodes.push(E('p', { 'class': 'om-muted om-meta' }, _('Probe URL: %s · Timeout: %s s · Retention: %s days · History refresh: 60 s').format(data.test_url || _('unknown'), number(data.timeout), number(data.retention_days))));
		}
		this.statusNode.replaceChildren.apply(this.statusNode, nodes);
		this.exportJson.disabled = this.exportCsv.disabled = !this.data || !!this.loading;
	},
	paint: function() {
		this.paintStatus();
		var data = this.data;
		var nodes = [];
		if (!data)
			nodes.push(E('div', { 'class': 'om-empty' }, _('Monitoring data is not available yet. Retrying in a minute.')));
		else if (!data.keys.length)
			nodes.push(E('div', { 'class': 'om-empty' }, _('No keys detected yet. History will appear after the first collector probe.')));
		else {
			var self = this;
			var now = data.now + Math.max(0, Math.floor((Date.now() - this.receivedAt) / 1000));
			var active = data.keys.filter(function(key) { return key.active !== false; });
			var archived = data.keys.filter(function(key) { return key.active === false; });
			nodes.push(renderComparison(data, now, self.dataHours, !!self.error || !!data.collector_error));
			[ [ active, _('Current keys') ], [ archived, _('Archive · replaced keys') ] ].forEach(function(group) {
				if (!group[0].length)
					return;
				nodes.push(E('h3', { 'class': 'om-section-title' }, group[1] + ' · ' + group[0].length));
				group[0].forEach(function(key) { nodes.push(renderKey(key, data, now, self.dataHours, !!self.error || !!data.collector_error)); });
			});
		}
		this.contentNode.replaceChildren.apply(this.contentNode, nodes);
	},
	download: function(format) {
		if (!this.data)
			return;
		var contents = format === 'json' ? JSON.stringify(this.data, null, 2) : csvData(this.data);
		var url = URL.createObjectURL(new Blob([ contents ], { type: format === 'json' ? 'application/json;charset=utf-8' : 'text/csv;charset=utf-8' }));
		var link = E('a', { href: url, download: 'outbound-monitor-' + this.dataHours + 'h-' + new Date(this.data.now * 1000).toISOString().replace(/[:.]/g, '-') + '.' + format });
		document.body.appendChild(link);
		link.click();
		link.remove();
		setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
	},
	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
