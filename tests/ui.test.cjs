'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(path.join(__dirname, '../luci-app-outbound-monitor/htdocs/luci-static/resources/view/outbound-monitor/status.js'), 'utf8');
const formatPrelude = "String.prototype.format = function() { var args = arguments, index = 0; return this.replace(/%s/g, function() { return String(args[index++]); }); };\n";
const context = { _: value => value, document: { documentElement: { lang: 'en-US' } }, rpc: { declare: () => () => Promise.resolve({}) } };
const helpers = vm.runInNewContext(formatPrelude + '(function() {\n' + source.slice(0, source.indexOf('return view.extend({')) + '\nreturn { samplesInRange, statistics, comparisonRows, keyState, chartGeometry, sampleLabel, tickLabel, percentage, csvData, validData, validUpdater }; })()', context);
const plain = value => JSON.parse(JSON.stringify(value));

test('range filtering orders, deduplicates, and preserves unknown samples', () => {
  const samples = helpers.samplesInRange([[900, 1, 2], [300, 0, 14], [600, -1, null], [300, 1, 0], [1200, 1, null], [1500, 1, 8], null], 300, 1200);
  assert.deepEqual(plain(samples), [[300, 1, 0], [600, -1, null], [900, 1, 2], [1200, -1, null]]);
});

test('availability excludes unknown and missed probes without implying uptime', () => {
  const result = helpers.statistics([[300, 1, 30], [600, -1, null], [900, 0, null], [1800, 1, 10]], 300);
  assert.equal(result.availability, 200 / 3);
  assert.equal(result.median, 20);
  assert.equal(result.success, 2);
  assert.equal(result.failed, 1);
  assert.equal(result.unknown, 1);
  assert.equal(result.missing, 2);
  assert.equal(helpers.statistics([[300, -1, null]], 300).availability, null);
  assert.equal(helpers.statistics([], 300).median, null);
  assert.equal(helpers.percentage(2015 / 2016 * 100), '99.95%');
  assert.notEqual(helpers.percentage(99.9999), '100%');
});

test('number formatting follows the LuCI page language', () => {
  context.document.documentElement.lang = 'ru-RU';
  try {
    assert.equal(helpers.percentage(99.95), '99,95%');
    assert.equal(helpers.percentage(99.9999), '>99,99%');
  }
  finally { context.document.documentElement.lang = 'en-US'; }
  assert.equal(helpers.percentage(99.95), '99.95%');
});

test('mean and population variance use successes only with an independent known data set', () => {
  // This data set has exact mean 5, population variance 4, and standard deviation 2.
  const samples = [2, 4, 4, 4, 5, 5, 7, 9].map((value, index) => [(index + 1) * 300, 1, value]);
  samples.push([2700, 0, null], [3000, -1, null], [3300, -2, null], [3900, -2, null]);
  const result = helpers.statistics(samples, 300);
  assert.equal(result.mean, 5);
  assert.ok(Math.abs(result.variance - 4) <= 32 * samples.length * Number.EPSILON);
  assert.ok(Math.abs(result.stddev - 2) <= 32 * samples.length * Number.EPSILON);
  assert.equal(result.failurePercent, 100 / 9);
  assert.equal(result.success, 8);
  assert.equal(result.failed, 1);
  assert.equal(result.unknown, 1);
  assert.equal(result.upstream, 2);
  assert.equal(result.missing, 1);
});

test('statistics distinguish missing denominators, a single success, and large values', () => {
  for (const samples of [[], [[300, -1, null]], [[300, -2, null]]]) {
    const result = helpers.statistics(samples, 300);
    for (const field of ['mean', 'variance', 'stddev', 'failurePercent', 'availability'])
      assert.equal(result[field], null);
  }
  const single = helpers.statistics([[300, 1, 42]], 300);
  assert.equal(single.mean, 42);
  assert.equal(single.variance, 0);
  assert.equal(single.stddev, 0);
  assert.equal(single.success, 1);
  const identical = helpers.statistics([[300, 1, Number.MAX_VALUE], [600, 1, Number.MAX_VALUE]], 300);
  assert.equal(identical.mean, Number.MAX_VALUE);
  assert.equal(identical.variance, 0);
  const offset = helpers.statistics([1, 2, 3].map((value, index) => [index * 300, 1, 1e12 + value]), 300);
  assert.equal(offset.mean, 1e12 + 2);
  assert.ok(Math.abs(offset.variance - 2 / 3) <= 32 * Number.EPSILON);
});

test('comparison selects the period, excludes archives, and sorts failures before mean', () => {
  const make = (id, samples, other = {}) => ({ id, tag: id + '-out', label: id, active: true, last_checked: 10000, current: 1, samples, ...other });
  const data = { interval: 300, keys: [
    make('unknown', [[7000, -1, null], [7300, -2, null]]),
    make('slow', [[6000, 0, null], [7000, 1, 100]]),
    make('failed', [[7000, 1, 1], [7300, 0, null]]),
    make('archive', [[7000, 1, 1]], { active: false }),
    make('stable-id', [[7000, 1, 20]], { label: 'renamed-key', tag: 'new-tag', current: -2 }),
    make('no-success', [[7000, 0, null]], { current: 0 })
  ] };
  const rows = helpers.comparisonRows(data, 10000, 1, false);
  assert.deepEqual(plain(rows.map(row => row.key.id)), ['stable-id', 'slow', 'failed', 'no-success', 'unknown']);
  assert.equal(rows[0].key.label, 'renamed-key');
  assert.equal(rows[0].key.tag, 'new-tag');
  assert.equal(rows[0].state.kind, 'upstream');
  assert.equal(rows[1].stats.failurePercent, 0);
  assert.equal(rows[4].stats.failurePercent, null);
  assert.equal(rows[4].stats.upstream, 1);
  assert.equal(helpers.comparisonRows(data, 11000, 1, false)[0].state.kind, 'unknown');
  assert.ok(helpers.comparisonRows(data, 10000, 1, true).every(row => row.state.kind === 'unknown'));
});

test('freshness and RPC availability override last successful status', () => {
  const key = { active: true, last_checked: 1000, current: 1, consecutive_failures: 3 };
  assert.equal(helpers.keyState(key, 1600, 300, false).kind, 'ok');
  assert.equal(helpers.keyState(key, 1601, 300, false).kind, 'unknown');
  assert.equal(helpers.keyState(key, 1000, 300, true).kind, 'unknown');
  assert.equal(helpers.keyState({ ...key, last_checked: 0 }, 1000, 300, false).kind, 'unknown');
  assert.equal(helpers.keyState({ ...key, last_checked: 1600 }, 1000, 300, false).kind, 'unknown');
  assert.equal(helpers.keyState({ ...key, active: false }, 1000, 300, false).kind, 'archive');
});

test('replacement advice requires three fresh consecutive failures', () => {
  const key = { active: true, last_checked: 1000, current: 0, consecutive_failures: 3 };
  assert.equal(helpers.keyState(key, 1000, 300, false).replace, true);
  for (const candidate of [{ ...key, consecutive_failures: 2 }, { ...key, current: -1 }, { ...key, active: false }])
    assert.equal(helpers.keyState(candidate, 1000, 300, false).replace, false);
  assert.equal(helpers.keyState(key, 1601, 300, false).replace, false);
  assert.equal(helpers.keyState(key, 1000, 300, true).replace, false);
  assert.equal(helpers.keyState({ ...key, current: -2 }, 1000, 300, false).replace, false);
});

test('chart never joins successes across unknowns, failures, or missed intervals', () => {
  const chart = helpers.chartGeometry([[300, 1, 30], [600, 1, 20], [900, -1, null], [1200, 1, 20], [1500, 0, null], [1800, 1, 30], [2700, 1, 10], [3000, 1, 50]], 0, 3600, 300);
  assert.deepEqual(plain(chart.paths.map(segment => segment.map(point => point.sample[0]))), [[300, 600], [1200], [1800], [2700, 3000]]);
  assert.equal(chart.points.length, 7);
  assert.equal(chart.points.find(point => point.sample[1] === 0).y, chart.y(-10));
});

test('zero, empty, single-value, and huge delay scales stay finite with a separate failure band', () => {
  for (const delay of [0, 1, 60000, 1e100, Number.MAX_VALUE]) {
    const chart = helpers.chartGeometry([[100, 1, delay]], 0, 200, 300);
    assert.ok(Number.isFinite(chart.maximum));
    assert.equal(chart.minimum, delay);
    assert.equal(chart.maximum, delay);
    assert.ok(Number.isFinite(chart.points[0].y));
    assert.ok(chart.points[0].y >= chart.top);
    assert.ok(chart.points[0].y <= chart.zero);
    assert.ok(chart.y(-10) - chart.y(0) >= 25);
    assert.ok(helpers.tickLabel(chart.maximum).length < 14);
    assert.equal(chart.ticks[0], delay);
    assert.equal(chart.ticks[chart.ticks.length - 1], chart.maximum);
    assert.ok(chart.ticks.every(tick => Number.isFinite(tick) && Number.isFinite(chart.y(tick))));
    assert.ok(chart.ticks.every((tick, index) => !index || tick > chart.ticks[index - 1]));
  }
  const empty = helpers.chartGeometry([[100, 0, null], [200, -2, null]], 0, 300, 300);
  assert.ok(Number.isFinite(empty.x(0)));
  assert.ok(empty.ticks.every(tick => Number.isFinite(empty.y(tick))));
  assert.ok(empty.points.every(point => point.y === empty.failure));
  const adjacent = helpers.chartGeometry([[100, 1, 1e300], [200, 1, 1e300 + 1e284]], 0, 300, 300);
  assert.ok(adjacent.points.every(point => Number.isFinite(point.y) && point.y >= adjacent.top && point.y <= adjacent.zero));
  assert.ok(adjacent.points[0].y > adjacent.points[1].y, 'nearby extreme values remain visually distinct');
  assert.equal(new Set(adjacent.ticks.map(tick => helpers.tickLabel(tick, adjacent.tickPrecision))).size, adjacent.ticks.length);
});

test('logarithmic delay axis spans the observed positive minimum and maximum with a small margin', () => {
  const narrow = helpers.chartGeometry([[300, 1, 138], [600, 1, 166], [900, 1, 2044]], 0, 1200, 300);
  assert.equal(narrow.minimum, 138);
  assert.equal(narrow.maximum, 2044);
  assert.equal(narrow.ticks[0], 138);
  assert.equal(narrow.ticks.at(-1), 2044);
  assert.ok(narrow.y(138) < narrow.zero && narrow.y(138) > narrow.zero - 20, 'minimum has a small lower margin');
  assert.ok(narrow.y(2044) > narrow.top && narrow.y(2044) < narrow.top + 20, 'maximum has a small upper margin');
  assert.ok(narrow.points.every(point => point.y >= narrow.top && point.y <= narrow.zero));
  assert.ok(narrow.ticks.every((tick, index) => !index || narrow.y(narrow.ticks[index - 1]) - narrow.y(tick) >= 28));
  assert.equal(new Set(narrow.ticks.map(tick => helpers.tickLabel(tick, narrow.tickPrecision))).size, narrow.ticks.length);
  const close = helpers.chartGeometry([[300, 1, 100], [600, 1, 100.1]], 0, 900, 300);
  assert.ok(close.y(100) - close.y(100.1) > 120, 'a narrow observed range fills the plot');
  assert.equal(close.ticks[0], 100);
  assert.equal(close.ticks.at(-1), 100.1);
  assert.equal(new Set(close.ticks.map(tick => helpers.tickLabel(tick, close.tickPrecision))).size, close.ticks.length);
  const later = helpers.chartGeometry([[600, 1, 166], [900, 1, 2044]], 600, 1200, 300);
  assert.equal(later.minimum, 166);
  assert.ok(later.y(166) > later.top, 'range selection recomputes the scale');
  assert.equal(narrow.y(-10), narrow.failure);
  assert.ok(narrow.y(-10) > narrow.zero);
});

test('logarithmic zero-inclusive axis compresses decades without moving failures', () => {
  const chart = helpers.chartGeometry([0, 1, 10, 100, 1000].map((delay, index) => [index * 300, 1, delay]), 0, 1200, 300);
  assert.deepEqual(plain(chart.ticks), [0, 10, 100, 1000]);
  assert.equal(chart.y(0), chart.zero);
  assert.ok(chart.y(1000) > chart.top && chart.y(1000) < chart.top + 10);
  const lowDecade = chart.y(10) - chart.y(100);
  const highDecade = chart.y(100) - chart.y(1000);
  assert.ok(Math.abs(lowDecade - highDecade) < 3);
  assert.equal(chart.y(-10), chart.failure);
  assert.ok(chart.y(-10) > chart.y(0));
});

test('yellow outliers use only successes in the selected period and a strict mean plus population SD threshold', () => {
  const history = [[0, 1, 1000], [300, 1, 10], [600, 1, 10], [900, 1, 10], [1200, 1, 50], [1500, 0, null], [1800, -2, null]];
  const selected = helpers.samplesInRange(history, 300, 1800);
  const chart = helpers.chartGeometry(selected, 300, 1800, 300);
  assert.ok(chart.outlierThreshold > 10 && chart.outlierThreshold < 50);
  assert.deepEqual(plain(chart.points.map(point => [point.sample[0], point.outlier])), [[300, false], [600, false], [900, false], [1200, true], [1500, false], [1800, false]]);
  assert.match(helpers.sampleLabel(selected[3], true), /Above mean \+ 1 SD/);
  assert.doesNotMatch(helpers.sampleLabel(selected[0], false), /Above mean/);
  const equal = helpers.chartGeometry([[300, 1, 0], [600, 1, 2]], 0, 900, 300);
  assert.equal(equal.outlierThreshold, 2);
  assert.equal(equal.points[1].outlier, false);
});

test('orange points exceed mean plus three population SD with priority over yellow', () => {
  const history = [[0, 1, 10000], ...Array.from({ length: 30 }, (_, i) => [(i + 1) * 300, 1, 10]), [9300, 1, 20], [9600, 1, 20], [9900, 1, 20], [10200, 1, 50], [10500, 0, null], [10800, -2, null]];
  const selected = helpers.samplesInRange(history, 300, 10800);
  const chart = helpers.chartGeometry(selected, 300, 10800, 300);
  assert.ok(20 > chart.outlierThreshold && 20 <= chart.extremeThreshold);
  assert.ok(50 > chart.extremeThreshold);
  assert.equal(chart.points.find(point => point.sample[2] === 20).outlier, true);
  assert.equal(chart.points.find(point => point.sample[2] === 20).extreme, false);
  assert.equal(chart.points.find(point => point.sample[2] === 50).extreme, true);
  assert.match(helpers.sampleLabel([10200, 1, 50], 3), /Above mean \+ 3 SD/);
  assert.doesNotMatch(helpers.sampleLabel([10200, 1, 50], 3), /Above mean \+ 1 SD/);
  assert.equal(helpers.chartGeometry([[300, 1, 0], [600, 1, 2]], 0, 900, 300).points[1].extreme, false);
});

test('external failures stay distinct from unknown gaps and are plotted at minus ten', () => {
  const samples = helpers.samplesInRange([[300, 1, 10], [600, -2, 90], [900, -1, null], [1200, 1, 20]], 0, 1500);
  assert.deepEqual(plain(samples[1]), [600, -2, null]);
  const chart = helpers.chartGeometry(samples, 0, 1500, 300);
  assert.equal(chart.points.length, 3);
  assert.equal(chart.points[1].sample[1], -2);
  assert.equal(chart.points[1].y, chart.y(-10));
  assert.deepEqual(plain(chart.paths.map(segment => segment.length)), [1, 1]);
  assert.match(helpers.sampleLabel(samples[1]), /external network failure suspected/);
});

test('CSV preserves key identity, quotes cells, and neutralizes spreadsheet formulas', () => {
  const csv = helpers.csvData({ keys: [{ id: 'old-id', label: '=SUM(1)', tag: 'a,"b', type: 'vless', server: 'host:443', groups: ['main'], active: false, samples: [[1700000000, 0, null], [1700000300, -1, null], [1700000600, -2, null]] }] });
  assert.ok(csv.startsWith('\uFEFF"id"'));
  assert.ok(csv.includes('"\'=SUM(1)"'));
  assert.ok(csv.includes('"a,""b"'));
  assert.ok(csv.includes('"false","2023-11-14T22:13:20.000Z","0",""'));
  assert.ok(csv.includes('"-1",""'));
  assert.ok(csv.includes('"-2",""'));
});

test('invalid RPC payloads fail visibly instead of rendering an empty healthy state', () => {
  for (const data of [{}, { version: 2, now: 1000, keys: [] }, { version: 1, now: 1000, keys: [null] }])
    assert.throws(() => helpers.validData(data));
  const data = { version: 1, now: 1000, keys: [] };
  assert.equal(helpers.validData(data), data);
});

class Node {
  constructor(tag, attributes = {}, children = []) {
    this.tag = tag;
    this.attributes = attributes;
	this.disabled = Object.prototype.hasOwnProperty.call(attributes, 'disabled') && attributes.disabled != null;
    this.children = [];
    this.replaceChildren(...(Array.isArray(children) ? children : [children]));
  }
  appendChild(child) { this.children.push(child); return child; }
  replaceChildren(...children) { this.children = children.filter(child => child !== null && child !== undefined); }
  setAttribute(name, value) { this.attributes[name] = value; }
  addEventListener() {}
  get textContent() { return this.children.map(child => child instanceof Node ? child.textContent : String(child)).join(' '); }
  set textContent(value) { this.children = [value]; }
}

function descendants(node) {
  return [node, ...node.children.filter(child => child instanceof Node).flatMap(descendants)];
}

const idleUpdater = { current: '2026-9-23-1', latest: null, checked_at: null, available: false, running: false, stage: 'idle', error: null, release_url: null };
function makeView(handler, updaterHandler = () => Promise.resolve(idleUpdater), lang = 'en-US') {
  const polls = [];
  const reloads = [];
  const context = {
    rpc: { declare: config => {
      if (config.method === 'status') {
        assert.deepEqual(plain(config), { object: 'luci.outbound-monitor', method: 'status', params: ['hours'], expect: {} });
        return handler;
      }
      assert.ok(['update_status', 'check_update', 'update'].includes(config.method));
      assert.deepEqual(plain(config), { object: 'luci.outbound-monitor', method: config.method, expect: {} });
      return (...args) => { assert.equal(args.length, 0); return updaterHandler(config.method); };
    } },
    _: value => value,
    view: { extend: value => value },
    poll: { add: (callback, interval) => polls.push({ callback, interval }) },
    E: (tag, attrs, children) => new Node(tag, attrs, children),
    L: { resource: path => '/luci-static/resources/' + path },
    document: { documentElement: { lang }, createElementNS: (_, tag) => new Node(tag), createTextNode: value => value },
    window: { location: { reload: () => reloads.push(true) } }
  };
  return { view: vm.runInNewContext(formatPrelude + '(function() {\n' + source + '\n})()', context), polls, reloads };
}

test('the rendered page handles empty data and separates archived identities', () => {
  const { view, polls } = makeView(() => Promise.resolve({}));
  const data = { version: 1, now: 1000, interval: 300, storage: 'ram', keys: [] };
  view.render({ data });
  assert.match(view.contentNode.textContent, /No keys detected yet/);
  assert.equal(polls[0].interval, 5);
  data.keys = [
    { id: 'new', label: 'vpn', active: true, current: 1, last_checked: 1000, samples: [[1000, 1, 30]] },
    { id: 'old', label: 'vpn', active: false, current: 1, last_checked: 1000, samples: [[700, 1, 40]] }
  ];
  view.paint();
  assert.match(view.contentNode.textContent, /Current keys · 1/);
  assert.match(view.contentNode.textContent, /Archive · replaced keys · 1/);
  assert.match(view.contentNode.textContent, /ID old/);
  assert.match(view.contentNode.textContent, /ID new/);
  assert.match(view.statusNode.textContent, /History is in RAM/);
});

test('interface-bound WARP and standalone keys display their own endpoints with unchanged statistics', () => {
  const { view } = makeView(() => Promise.resolve({}));
  const warp = { id: 'warp-config', label: 'warp-out', tag: 'warp-out', type: 'direct', interface: 'awg0', server: '', active: true, current: 1, last_checked: 1000, samples: [[700, 1, 20], [1000, 1, 40]], groups: [] };
  const standalone = { id: 'single-config', label: 'single-out', tag: 'single-out', type: 'vless', interface: null, server: 'example.test:443', active: true, current: 1, last_checked: 1000, samples: [[1000, 1, 15]], groups: [] };
  const data = { version: 1, now: 1000, interval: 300, keys: [warp, standalone] };
  view.render({ data });
  const comparison = view.contentNode.children[0];
  assert.match(comparison.textContent, /Interface: awg0/);
  const details = descendants(view.contentNode).filter(node => node.attributes.class === 'om-muted om-key-details');
  assert.deepEqual(details.map(node => node.textContent), ['direct · Interface: awg0', 'vless · example.test:443']);
  assert.doesNotMatch(view.contentNode.textContent, /unknown server/);
  const stats = helpers.comparisonRows(data, 1000, 24, false).find(row => row.key.id === warp.id).stats;
  assert.equal(stats.mean, 30);
  assert.equal(stats.variance, 100);
  assert.equal(stats.failurePercent, 0);
  assert.deepEqual(warp.samples, [[700, 1, 20], [1000, 1, 40]]);
});

test('median card shows population SD with page-locale formatting and chart legend explains orange', () => {
  const data = { version: 1, now: 1000, interval: 300, keys: [{ id: 'key', label: 'test', active: true, current: 1, last_checked: 1000, samples: [[700, 1, 161.4], [1000, 1, 170.6]] }] };
  const { view } = makeView(() => Promise.resolve({}), undefined, 'ru-RU');
  const root = view.render({ data });
  const median = descendants(view.contentNode).find(node => node.attributes.class === 'om-metric' && /Median HTTP delay/.test(node.textContent));
  assert.match(median.textContent, /166 ± 4,6 ms/);
  assert.match(median.textContent, /median ± population SD of successful probes/);
  assert.match(root.textContent, /Above mean \+ 3 SD/);
  assert.match(root.textContent, /small margin/);
  const chart = descendants(root).find(node => node.tag === 'svg');
  assert.match(chart.textContent, /observed minimum and maximum/);
});

test('rendered chart keeps yellow and orange successes above the red failure band', () => {
  const successes = [...Array.from({ length: 30 }, (_, i) => [(i + 1) * 300, 1, 10]), [9300, 1, 20], [9600, 1, 20], [9900, 1, 20], [10200, 1, 50]];
  const data = { version: 1, now: 10800, interval: 300, keys: [{ id: 'key', active: true, current: -2, last_checked: 10800, samples: [...successes, [10500, 0, null], [10800, -2, null]] }] };
  const { view } = makeView(() => Promise.resolve({}));
  view.render({ data });
  const chart = descendants(view.contentNode).find(node => node.tag === 'svg');
  const nodes = descendants(chart);
  const circles = nodes.filter(node => node.tag === 'circle');
  assert.equal(circles.filter(node => node.attributes.class === 'om-outlier-point').length, 3);
  assert.equal(circles.filter(node => node.attributes.class === 'om-extreme-point').length, 1);
  assert.equal(circles.filter(node => node.attributes.class === 'om-failed-point').length, 1);
  assert.equal(circles.filter(node => node.attributes.class === 'om-upstream-point').length, 1);
  const band = nodes.find(node => node.attributes.class === 'om-error-band');
  assert.equal(circles.find(node => node.attributes.class === 'om-failed-point').attributes.cy, 208);
  assert.ok(band.attributes.y < 208 && band.attributes.y + band.attributes.height > 208);
  assert.match(circles.find(node => node.attributes.class === 'om-extreme-point').textContent, /Above mean \+ 3 SD/);
});

test('range races cannot overwrite a newer response and RPC failure is visible', async () => {
  const pending = [];
  const { view } = makeView(hours => new Promise((resolve, reject) => pending.push({ hours, resolve, reject })));
  const initial = { version: 1, now: 1000, interval: 300, keys: [{ id: 'key', active: true, current: 1, last_checked: 1000, samples: [[1000, 1, 10]] }] };
  view.render({ data: initial });
  view.hours = 1;
  const older = view.refresh();
  view.hours = 6;
  const newer = view.refresh();
  assert.equal(view.exportJson.disabled, true);
  pending[1].resolve({ ...initial, now: 1001 });
  await newer;
  pending[0].resolve({ ...initial, now: 999 });
  await older;
  assert.equal(view.dataHours, 6);
  assert.equal(view.data.now, 1001);
  assert.equal(view.exportCsv.disabled, false);
  assert.match(view.contentNode.textContent, /Probe succeeded/);
  const failed = view.refresh();
  pending[2].reject(new Error('RPC offline'));
  await failed;
  assert.match(view.statusNode.textContent, /RPC offline/);
  assert.match(view.statusNode.textContent, /previously received data for 6 hours/);
  assert.match(view.contentNode.textContent, /No fresh response/);
  assert.doesNotMatch(view.contentNode.textContent, /Probe succeeded/);
});

test('comparison precedes charts and connectivity diagnoses remain conditional', () => {
  const { view } = makeView(() => Promise.resolve({}));
  const data = { version: 1, now: 10000, interval: 300, connectivity: { reason: 'direct_failed', status: 0, checked_at: 10000 }, keys: [
    { id: 'current', label: 'new label', tag: 'new tag', active: true, current: -2, last_checked: 10000, samples: [[9700, 1, 10], [10000, -2, null]] },
    { id: 'old', label: 'old label', active: false, current: 1, last_checked: 10000, samples: [[9700, 1, 1]] }
  ] };
  view.render({ data });
  const comparison = view.contentNode.children[0];
  assert.equal(comparison.attributes.class, 'om-comparison');
  assert.match(comparison.textContent, /Active outbounds · 24 hours/);
  assert.match(comparison.textContent, /new label/);
  assert.match(comparison.textContent, /new tag/);
  assert.doesNotMatch(comparison.textContent, /old label/);
  assert.match(comparison.textContent, /External failures: 1/);
  assert.match(comparison.textContent, /Known probes: 1 · successful: 1/);
  assert.match(view.statusNode.textContent, /both direct checks and all VPN probes failed/);
  assert.match(view.statusNode.textContent, /issue is possible/);
  data.connectivity.reason = 'mixed';
  data.keys[0].current = 1;
  view.paint();
  assert.match(view.statusNode.textContent, /at least one VPN probe succeeded/);
  assert.doesNotMatch(view.statusNode.textContent, /ISP/);
  data.connectivity.reason = 'direct_failed';
  view.paint();
  assert.doesNotMatch(view.statusNode.textContent, /all VPN probes failed/);
});

test('DNS details retain their actual timestamp, explain the route, and bound incident rows', () => {
  const { view } = makeView(() => Promise.resolve({}));
  const dns = { checked_at: 9700, status: 'issues', route: 'router', summary: { ok: 1, mismatch: 1, warning: 0, failed: 0 }, resolvers: [{ id: 'resolver', name: 'Example DNS', status: 'mismatch', dot: 'ok', doh: 'mismatch' }], error: null };
  const events = Array.from({ length: 25 }, (_, i) => ({ checked_at: 10000 + i * 300, connectivity: { status: 0, reason: 'direct_failed' }, dns }));
  const data = { version: 1, now: 20000, keys: [], dns, dns_enabled: true, dns_available: true, network_events: events };
  view.render({ data });
  assert.match(view.statusNode.textContent, /Example DNS/);
  assert.match(view.statusNode.textContent, /Mismatch/);
  assert.match(view.statusNode.textContent, /may include a VPN/);
  assert.match(view.statusNode.textContent, /do not prove an ISP failure or DNS tampering/);
  assert.ok(view.statusNode.textContent.includes(new Date(9700 * 1000).toLocaleString('en-US')));
  const table = descendants(view.statusNode).find(node => node.attributes.class === 'om-diagnostic-table om-event-table');
  const body = table.children.find(node => node.tag === 'tbody');
  assert.equal(body.children.length, 20);
  assert.ok(body.children[0].textContent.includes(new Date(17200 * 1000).toLocaleString('en-US')));
  assert.equal(events[0].checked_at, 10000, 'rendering must not reorder data exported as JSON');
  data.dns_enabled = false;
  data.now = 20300;
  data.connectivity = { status: 1, reason: 'ok', checked_at: 20300 };
  view.paint();
  assert.match(view.statusNode.textContent, /DNS diagnostics are disabled/);
  assert.ok(view.statusNode.textContent.includes(new Date(9700 * 1000).toLocaleString('en-US')));
  assert.equal(data.dns, dns);
});

test('DNS not-run and missing-IPRegion states do not invent an execution time', () => {
  const { view } = makeView(() => Promise.resolve({}));
  const data = { version: 1, now: 10000, keys: [], dns: { status: 'not_run', checked_at: null } };
  view.render({ data });
  assert.match(view.statusNode.textContent, /have not run yet/);
  assert.equal(descendants(view.statusNode).filter(node => node.tag === 'details').length, 0);
  data.dns = { status: 'not_installed', checked_at: null };
  view.paint();
  assert.match(view.statusNode.textContent, /require IPRegion/);
  assert.equal(descendants(view.statusNode).filter(node => node.tag === 'details').length, 0);
});

test('DNS v2 adds UDP and TCP without dropping encrypted transports or v1 rows', () => {
  const { view } = makeView(() => Promise.resolve({}));
  const encrypted = { id: 'encrypted', name: 'Encrypted DNS', status: 'ok', dot: 'ok', doh: 'ok' };
  const dns = { checked_at: 9700, status: 'ok', route: 'router', summary: { ok: 1, mismatch: 0, warning: 0, failed: 0 }, resolvers: [encrypted] };
  view.render({ data: { version: 1, now: 10000, keys: [], dns } });
  let table = descendants(view.statusNode).find(node => node.attributes.class === 'om-diagnostic-table');
  assert.deepEqual(table.children[0].children[0].children.map(node => node.textContent), ['Resolver', 'Result', 'DoT', 'DoH']);
  dns.resolvers.unshift({ id: 'interface_dns', name: 'Interface DNS', ip_version: 4, status: 'ok', udp: 'ok', tcp: 'ok', dot: 'not_tested', doh: 'not_tested' });
  view.paint();
  table = descendants(view.statusNode).find(node => node.attributes.class === 'om-diagnostic-table');
  assert.deepEqual(table.children[0].children[0].children.map(node => node.textContent), ['Resolver', 'Result', 'UDP', 'TCP', 'DoT', 'DoH']);
  const rows = table.children[1].children;
  assert.deepEqual(rows[0].children.map(node => node.textContent), ['Interface DNS · IPv4', 'OK', 'OK', 'OK', 'Not tested', 'Not tested']);
  assert.deepEqual(rows[1].children.map(node => node.textContent), ['Encrypted DNS', 'OK', '—', '—', 'OK', 'OK']);
  dns.resolvers[0].ip_version = 6;
  dns.resolvers[0].status = 'partial';
  view.paint();
  table = descendants(view.statusNode).find(node => node.attributes.class === 'om-diagnostic-table');
  assert.match(table.textContent, /Interface DNS · IPv6 Partial result/);
});

test('reloading after an update changes the stylesheet cache key', () => {
  const href = current => {
    const { view } = makeView(() => Promise.resolve({}));
    const root = view.render({ data: { version: 1, now: 1000, keys: [] }, updater: { ...idleUpdater, current } });
    return descendants(root).find(node => node.tag === 'link').attributes.href;
  };
  assert.equal(href('2026-9-23-1'), href('2026-9-23-1'));
  assert.notEqual(href('2026-9-23-1'), href('2026-9-23-2'));
});

test('updater gates install, polls small status, and offers reload only after installation', async () => {
  const calls = [];
  let state = idleUpdater;
  let historyCalls = 0;
  const { view, reloads } = makeView(() => { historyCalls++; return Promise.resolve({ version: 1, now: 1000, keys: [] }); }, method => {
    calls.push(method);
    if (method === 'check_update') state = { ...state, stage: 'checking', running: true };
    if (method === 'update') state = { ...state, stage: 'updating', running: true };
    return Promise.resolve(state);
  });
  view.render({ data: { version: 1, now: 1000, keys: [] }, updater: state });
  assert.equal(view.updateButton.disabled, true);
  assert.equal(view.checkButton.disabled, false);
  await view.refreshUpdater('install');
  assert.deepEqual(calls, []);
  await view.refreshUpdater('check');
  assert.equal(view.checkButton.disabled, true);
  assert.equal(view.updateButton.disabled, true);
  state = { ...idleUpdater, latest: '2026-9-23-2', checked_at: 1000, available: true };
  await view.tick();
  assert.equal(view.updateButton.disabled, false);
  assert.equal(historyCalls, 0);
  await view.refreshUpdater('install');
  assert.equal(view.updateButton.disabled, true);
  state = { ...idleUpdater, current: '2026-9-23-2', latest: '2026-9-23-2', checked_at: 1000, stage: 'done' };
  await view.tick();
  assert.deepEqual(calls, ['check_update', 'update_status', 'update', 'update_status']);
  assert.equal(historyCalls, 0);
  assert.equal(view.reloadNeeded, true);
  assert.match(view.updaterNode.textContent, /Reload page/);
  assert.equal(reloads.length, 0);
});

test('lost update responses keep history, block duplicate writes, and reconcile by status', async () => {
  const calls = [];
  const data = { version: 1, now: 1000, keys: [{ id: 'key', active: true, current: 1, last_checked: 1000, samples: [[1000, 1, 10]] }] };
  const state = { ...idleUpdater, latest: '2026-9-23-2', available: true };
  const { view } = makeView(() => Promise.reject(new Error('RPC restarting')), method => {
    calls.push(method);
    return method === 'update' ? Promise.reject(new Error('RPC restarting')) : Promise.resolve({ ...state, current: '2026-9-23-2', available: false, stage: 'done' });
  });
  view.render({ data, updater: state });
  await view.refreshUpdater('install');
  assert.equal(view.data, data);
  assert.equal(view.updaterUncertain, true);
  assert.equal(view.checkButton.disabled, true);
  assert.match(view.updaterNode.textContent, /will not be sent again/);
  await view.refreshUpdater('install');
  assert.deepEqual(calls, ['update']);
  view.lastHistoryPoll -= 60001;
  await view.tick();
  assert.deepEqual(calls, ['update', 'update_status']);
  assert.equal(view.data, data);
  assert.equal(view.updaterUncertain, false);
  assert.equal(view.reloadNeeded, true);
  assert.match(view.statusNode.textContent, /RPC restarting/);
  assert.match(view.contentNode.textContent, /key/);
});

test('initial updater RPC failure does not prevent the history from loading', async () => {
  const data = { version: 1, now: 1000, keys: [] };
  const { view } = makeView(() => Promise.resolve(data), () => Promise.reject(new Error('Updater unavailable')));
  const result = await view.load();
  assert.equal(result.data, data);
  assert.equal(result.updaterError, 'Updater unavailable');
  view.render(result);
  assert.match(view.updaterNode.textContent, /Updater unavailable/);
  assert.equal(view.updateButton.disabled, true);
});
