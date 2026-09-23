'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(path.join(__dirname, '../luci-app-outbound-monitor/htdocs/luci-static/resources/view/outbound-monitor/status.js'), 'utf8');
const context = { rpc: { declare: () => () => Promise.resolve({}) } };
const helpers = vm.runInNewContext('(function() {\n' + source.slice(0, source.indexOf('return view.extend({')) + '\nreturn { samplesInRange, statistics, keyState, chartGeometry, tickLabel, percentage, csvData, validData }; })()', context);
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
  assert.equal(helpers.percentage(2015 / 2016 * 100), '99,95%');
  assert.notEqual(helpers.percentage(99.9999), '100%');
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
});

test('chart never joins successes across unknowns, failures, or missed intervals', () => {
  const chart = helpers.chartGeometry([[300, 1, 30], [600, 1, 20], [900, -1, null], [1200, 1, 20], [1500, 0, null], [1800, 1, 30], [2700, 1, 10], [3000, 1, 50]], 0, 3600, 300);
  assert.deepEqual(plain(chart.paths.map(segment => segment.map(point => point.sample[0]))), [[300, 600], [1200], [1800], [2700, 3000]]);
  assert.equal(chart.points.length, 7);
  assert.equal(chart.points.find(point => point.sample[1] === 0).y, chart.y(-10));
});

test('zero, empty, and huge delay scales stay finite with distinct failure band', () => {
  for (const delay of [0, 1, 60000, 1e100, Number.MAX_VALUE]) {
    const chart = helpers.chartGeometry([[100, 1, delay]], 0, 200, 300);
    assert.ok(Number.isFinite(chart.maximum));
    assert.ok(Number.isFinite(chart.points[0].y));
    assert.ok(chart.points[0].y >= chart.top);
    assert.ok(chart.points[0].y <= chart.zero);
    assert.ok(chart.y(-10) - chart.y(0) >= 25);
    assert.ok(helpers.tickLabel(chart.maximum).length < 14);
  }
  assert.ok(Number.isFinite(helpers.chartGeometry([], 0, 0, 300).x(0)));
});

test('CSV preserves key identity, quotes cells, and neutralizes spreadsheet formulas', () => {
  const csv = helpers.csvData({ keys: [{ id: 'old-id', label: '=SUM(1)', tag: 'a,"b', type: 'vless', server: 'host:443', groups: ['main'], active: false, samples: [[1700000000, 0, null], [1700000300, -1, null]] }] });
  assert.ok(csv.startsWith('\uFEFF"id"'));
  assert.ok(csv.includes('"\'=SUM(1)"'));
  assert.ok(csv.includes('"a,""b"'));
  assert.ok(csv.includes('"false","2023-11-14T22:13:20.000Z","0",""'));
  assert.ok(csv.includes('"-1",""'));
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

function makeView(handler) {
  const polls = [];
  const context = {
    rpc: { declare: config => { assert.deepEqual(plain(config), { object: 'luci.outbound-monitor', method: 'status', params: ['hours'], expect: {} }); return handler; } },
    view: { extend: value => value },
    poll: { add: (callback, interval) => polls.push({ callback, interval }) },
    E: (tag, attrs, children) => new Node(tag, attrs, children),
    L: { resource: path => '/luci-static/resources/' + path },
    document: { createElementNS: (_, tag) => new Node(tag), createTextNode: value => value }
  };
  return { view: vm.runInNewContext('(function() {\n' + source + '\n})()', context), polls };
}

test('the rendered page handles empty data and separates archived identities', () => {
  const { view, polls } = makeView(() => Promise.resolve({}));
  const data = { version: 1, now: 1000, interval: 300, storage: 'ram', keys: [] };
  view.render({ data });
  assert.match(view.contentNode.textContent, /Ключи пока не обнаружены/);
  assert.equal(polls[0].interval, 60);
  data.keys = [
    { id: 'new', label: 'vpn', active: true, current: 1, last_checked: 1000, samples: [[1000, 1, 30]] },
    { id: 'old', label: 'vpn', active: false, current: 1, last_checked: 1000, samples: [[700, 1, 40]] }
  ];
  view.paint();
  assert.match(view.contentNode.textContent, /Текущие ключи · 1/);
  assert.match(view.contentNode.textContent, /Архив · заменённые ключи · 1/);
  assert.match(view.contentNode.textContent, /ID old/);
  assert.match(view.contentNode.textContent, /ID new/);
  assert.match(view.statusNode.textContent, /История в RAM/);
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
  assert.match(view.contentNode.textContent, /Проверка успешна/);
  const failed = view.refresh();
  pending[2].reject(new Error('RPC offline'));
  await failed;
  assert.match(view.statusNode.textContent, /RPC offline/);
  assert.match(view.statusNode.textContent, /ранее полученные данные за 6 часов/);
  assert.match(view.contentNode.textContent, /Нет свежего ответа/);
  assert.doesNotMatch(view.contentNode.textContent, /Проверка успешна/);
});
