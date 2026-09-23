'use strict';
'require view';
'require rpc';
'require poll';

var callStatus = rpc.declare({ object: 'luci.outbound-monitor', method: 'status', params: [ 'hours' ], expect: {} });
var ranges = [ [ 1, '1 час' ], [ 6, '6 часов' ], [ 24, '24 часа' ], [ 168, '7 дней' ] ];

function finite(value) {
	return typeof value === 'number' && isFinite(value);
}

function dateTime(epoch) {
	return finite(epoch) && epoch > 0 ? new Date(epoch * 1000).toLocaleString('ru-RU') : 'нет данных';
}

function number(value) {
	return finite(value) ? value.toLocaleString('ru-RU', { maximumFractionDigits: 1 }) : '—';
}

function percentage(value) {
	if (!finite(value))
		return '—';
	return (value < 100 && value > 99.99 ? '>99,99' : value.toLocaleString('ru-RU', { maximumFractionDigits: 2 })) + '%';
}

function rangeLabel(hours) {
	return ranges.filter(function(item) { return item[0] === hours; })[0][1];
}

function samplesInRange(samples, from, to) {
	var byTime = Object.create(null);
	(Array.isArray(samples) ? samples : []).forEach(function(sample) {
		if (!Array.isArray(sample) || !finite(sample[0]) || sample[0] < from || sample[0] > to)
			return;
		var status = sample[1] === 1 || sample[1] === 0 ? sample[1] : -1;
		var delay = status === 1 && finite(sample[2]) && sample[2] >= 0 ? sample[2] : null;
		if (status === 1 && delay === null)
			status = -1;
		byTime[sample[0]] = [ sample[0], status, delay ];
	});
	return Object.keys(byTime).map(function(time) { return byTime[time]; }).sort(function(a, b) { return a[0] - b[0]; });
}

function statistics(samples, interval) {
	var result = { success: 0, failed: 0, unknown: 0, missing: 0, median: null, availability: null };
	var delays = [];
	samples.forEach(function(sample, index) {
		if (sample[1] === 1) {
			result.success++;
			delays.push(sample[2]);
		}
		else if (sample[1] === 0)
			result.failed++;
		else
			result.unknown++;
		if (index && sample[0] - samples[index - 1][0] > interval * 1.8)
			result.missing += Math.max(1, Math.round((sample[0] - samples[index - 1][0]) / interval) - 1);
	});
	var measured = result.success + result.failed;
	if (measured)
		result.availability = result.success * 100 / measured;
	if (delays.length) {
		delays.sort(function(a, b) { return a - b; });
		var middle = Math.floor(delays.length / 2);
		result.median = delays.length % 2 ? delays[middle] : delays[middle - 1] / 2 + delays[middle] / 2;
	}
	return result;
}

function keyState(key, now, interval, unavailable) {
	if (key.active === false)
		return { kind: 'archive', label: 'Архивный ключ', replace: false };
	if (unavailable)
		return { kind: 'unknown', label: 'Нет свежего ответа', replace: false };
	if (!finite(key.last_checked) || key.last_checked <= 0)
		return { kind: 'unknown', label: 'Ещё не проверен', replace: false };
	if (now - key.last_checked > interval * 2 || key.last_checked > now + interval)
		return { kind: 'unknown', label: 'Данные устарели', replace: false };
	if (key.current === 1)
		return { kind: 'ok', label: 'Проверка успешна', replace: false };
	if (key.current === 0)
		return { kind: 'failed', label: 'Ошибка проверки', replace: key.consecutive_failures >= 3 };
	return { kind: 'unknown', label: 'Результат неизвестен', replace: false };
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
			var point = { x: geometry.x(sample[0]), y: geometry.y(sample[1] === 0 ? -10 : sample[2]), sample: sample };
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
	return dateTime(sample[0]) + ' · ' + (sample[1] === 1 ? number(sample[2]) + ' мс' : sample[1] === 0 ? 'ошибка проверки (−10)' : 'нет результата');
}

function svgNode(tag, attributes, children) {
	var node = document.createElementNS('http://www.w3.org/2000/svg', tag);
	Object.keys(attributes || {}).forEach(function(name) { node.setAttribute(name, attributes[name]); });
	(children || []).forEach(function(child) { node.appendChild(typeof child === 'string' ? document.createTextNode(child) : child); });
	return node;
}

function renderChart(samples, from, to, interval, label) {
	var g = chartGeometry(samples, from, to, interval);
	var chart = svgNode('svg', { viewBox: '0 0 800 252', role: 'img', 'aria-label': label + ': задержка HTTP в миллисекундах' }, [
		svgNode('title', {}, [ label + ' — задержка HTTP, мс. Ошибки на отметке −10, неизвестные результаты и пропуски разрывают линию.' ]),
		svgNode('text', { x: g.left, y: 15, 'class': 'om-axis-title' }, [ 'HTTP, мс' ]),
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
		var text = date.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
		if (to - from >= 86400)
			text = date.toLocaleDateString('ru-RU', { day: '2-digit', month: '2-digit' }) + ' ' + text;
		chart.appendChild(svgNode('text', { x: g.x(time), y: 245, 'text-anchor': fraction === 0 ? 'start' : fraction === 1 ? 'end' : 'middle', 'class': 'om-axis' }, [ text ]));
	});
	g.paths.forEach(function(path) {
		if (path.length > 1)
			chart.appendChild(svgNode('polyline', { points: path.map(function(point) { return point.x + ',' + point.y; }).join(' '), 'class': 'om-trace' }));
	});
	g.points.forEach(function(point) {
		chart.appendChild(svgNode('circle', { cx: point.x, cy: point.y, r: point.sample[1] === 0 ? 4.5 : 3.6, 'class': point.sample[1] === 0 ? 'om-failed-point' : 'om-ok-point' }, [ svgNode('title', {}, [ sampleLabel(point.sample) ]) ]));
	});
	var cursor = svgNode('line', { x1: 0, x2: 0, y1: g.top, y2: 222, 'class': 'om-cursor', visibility: 'hidden' });
	chart.appendChild(cursor);
	var hint = E('div', { 'class': 'om-chart-hint', 'aria-live': 'polite' }, [ samples.length ? 'Наведите на график или коснитесь его для просмотра замера.' : 'В выбранном периоде ещё нет замеров.' ]);
	var index = samples.length - 1;
	function showSample(sample) {
		cursor.setAttribute('x1', g.x(sample[0]));
		cursor.setAttribute('x2', g.x(sample[0]));
		cursor.setAttribute('visibility', 'visible');
		hint.textContent = sampleLabel(sample);
	}
	chart.setAttribute('tabindex', samples.length ? '0' : '-1');
	chart.setAttribute('aria-description', 'Стрелки влево и вправо переключают замеры.');
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
	var label = key.label || key.tag || 'Без имени';
	var measured = stats.success + stats.failed;
	return E('section', { 'class': 'om-card' + (key.active === false ? ' om-archived' : '') }, [
		E('div', { 'class': 'om-card-heading' }, [
			E('div', {}, [ E('h3', {}, label), E('div', { 'class': 'om-muted om-key-details' }, [ (key.type || 'outbound') + ' · ' + (key.server || 'сервер неизвестен') ]), E('code', { 'class': 'om-fingerprint', title: key.id || '' }, 'ID ' + String(key.id || '—').slice(0, 12)) ]),
			E('span', { 'class': 'om-badge om-' + state.kind }, state.label)
		]),
		Array.isArray(key.groups) && key.groups.length ? E('p', { 'class': 'om-groups om-muted' }, 'Группы: ' + key.groups.join(', ')) : '',
		key.active === false ? E('p', { 'class': 'om-note' }, 'Этот ключ больше не используется в текущей конфигурации. Ниже сохранена его история.') : '',
		state.replace ? E('p', { 'class': 'om-advice' }, 'Неудачных проверок подряд: ' + key.consecutive_failures + '. Проверьте подключение и рассмотрите замену ключа. Ошибки не доказывают, что срок его действия истёк.') : '',
		E('div', { 'class': 'om-metrics' }, [
			metric('Успешные пробы', percentage(stats.availability), stats.success + ' из ' + measured + ' с известным результатом'),
			metric('Медиана HTTP', stats.median === null ? '—' : number(stats.median) + ' мс', 'по успешным пробам за период'),
			metric('Ошибки', String(stats.failed), 'неизвестных результатов: ' + stats.unknown)
		]),
		renderChart(samples, now - hours * 3600, now, interval, label),
		E('p', { 'class': 'om-footnote' }, 'Замеров: ' + samples.length + '. Пропусков между замерами: ≈' + stats.missing + '. Процент отражает отдельные пробы, а не непрерывное время работы.'),
		E('div', { 'class': 'om-times om-muted' }, [ E('span', {}, 'Последняя проверка: ' + dateTime(key.last_checked)), E('span', {}, 'Последний успех: ' + dateTime(key.last_success)) ])
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
		throw new Error('Монитор вернул некорректные данные');
	return data;
}

return view.extend({
	hours: 24,
	dataHours: 24,
	requestId: 0,
	load: function() {
		return callStatus(24).then(function(data) { return { data: validData(data) }; }).catch(function(error) { return { error: error.message || String(error) }; });
	},
	render: function(result) {
		this.data = result.data || null;
		this.error = result.error || null;
		this.receivedAt = Date.now();
		var self = this;
		var selector = E('select', { 'aria-label': 'Период истории', change: function(event) { self.hours = Number(event.target.value); self.refresh(); } }, ranges.map(function(item) {
			return E('option', { value: item[0], selected: item[0] === self.hours ? '' : null }, item[1]);
		}));
		this.exportJson = E('button', { 'class': 'cbi-button', click: function() { self.download('json'); } }, 'JSON');
		this.exportCsv = E('button', { 'class': 'cbi-button', click: function() { self.download('csv'); } }, 'CSV');
		this.statusNode = E('div', { 'class': 'om-status', 'aria-live': 'polite' });
		this.contentNode = E('div');
		var root = E('div', { 'class': 'om-page' }, [
			E('link', { rel: 'stylesheet', href: L.resource('outbound-monitor/style.css') }),
			E('div', { 'class': 'om-header' }, [ E('div', {}, [ E('h2', {}, 'Монитор исходящих подключений'), E('p', { 'class': 'om-muted' }, 'История HTTP-проверок каждого ключа') ]), E('div', { 'class': 'om-controls' }, [ E('label', {}, [ 'Период ', selector ]), E('span', { 'class': 'om-export-label' }, 'Экспорт:'), this.exportJson, this.exportCsv ]) ]),
			this.statusNode,
			E('div', { 'class': 'om-legend' }, [ E('span', { 'class': 'om-legend-success' }, '● Задержка HTTP, мс'), E('span', { 'class': 'om-legend-failure' }, '● Ошибка: −10'), E('span', {}, 'Разрывы — нет результата или замера') ]),
			E('p', { 'class': 'om-footnote' }, 'Выше нуля шкала линейная; −10 показано в отдельной полосе ошибок. Время отображается в часовом поясе браузера. Экспорт содержит полученные данные выбранного периода.'),
			this.contentNode
		]);
		this.paint();
		poll.add(this.refresh.bind(this), 60);
		return root;
	},
	refresh: function() {
		var self = this;
		var hours = this.hours;
		var request = ++this.requestId;
		this.loading = true;
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
			nodes.push(E('p', { 'class': 'om-alert', role: 'alert' }, 'Не удалось обновить монитор: ' + this.error + (this.data ? '. Показаны ранее полученные данные за ' + rangeLabel(this.dataHours) + '; текущий статус неизвестен.' : '. Проверьте, запущен ли сборщик.')));
		if (this.data && this.data.collector_error)
			nodes.push(E('p', { 'class': 'om-alert', role: 'alert' }, 'Ошибка сборщика: ' + this.data.collector_error + '. Текущий статус ключей неизвестен.'));
		if (this.loading)
			nodes.push(E('p', { 'class': 'om-muted' }, 'Обновление данных за ' + rangeLabel(this.hours) + '…'));
		if (this.data) {
			var data = this.data;
			nodes.push(E('p', { 'class': 'om-muted om-meta' }, 'История: ' + rangeLabel(this.dataHours) + ' · Проба каждые ' + number((data.interval || 300) / 60) + ' мин · Сборщик: ' + dateTime(data.updated_at) + ' · ' + (data.storage === 'ram' ? 'История в RAM; исчезнет при перезагрузке' : 'Хранилище: ' + (data.storage || 'неизвестно'))));
			nodes.push(E('p', { 'class': 'om-muted om-meta' }, 'Адрес проверки: ' + (data.test_url || 'неизвестен') + ' · Тайм-аут: ' + number(data.timeout) + ' с · Хранение: ' + number(data.retention_days) + ' дней · Обновление страницы: 60 с'));
		}
		this.statusNode.replaceChildren.apply(this.statusNode, nodes);
		this.exportJson.disabled = this.exportCsv.disabled = !this.data || !!this.loading;
	},
	paint: function() {
		this.paintStatus();
		var data = this.data;
		var nodes = [];
		if (!data)
			nodes.push(E('div', { 'class': 'om-empty' }, 'Данные мониторинга пока недоступны. Следующая попытка — через минуту.'));
		else if (!data.keys.length)
			nodes.push(E('div', { 'class': 'om-empty' }, 'Ключи пока не обнаружены. История появится после первой проверки сборщика.'));
		else {
			var self = this;
			var now = data.now + Math.max(0, Math.floor((Date.now() - this.receivedAt) / 1000));
			var active = data.keys.filter(function(key) { return key.active !== false; });
			var archived = data.keys.filter(function(key) { return key.active === false; });
			[ [ active, 'Текущие ключи' ], [ archived, 'Архив · заменённые ключи' ] ].forEach(function(group) {
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
