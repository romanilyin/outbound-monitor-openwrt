'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');

const root = path.join(__dirname, '../luci-app-outbound-monitor');
const source = fs.readFileSync(path.join(root, 'htdocs/luci-static/resources/view/outbound-monitor/status.js'), 'utf8');
const russian = fs.readFileSync(path.join(root, 'po/ru/outbound-monitor.po'), 'utf8');
const template = fs.readFileSync(path.join(root, 'po/templates/outbound-monitor.pot'), 'utf8');

function entries(text) {
  const result = new Map();
  for (const match of text.matchAll(/^msgid ("(?:\\.|[^"\\])*")\r?\nmsgstr ("(?:\\.|[^"\\])*")/gm)) {
    const key = JSON.parse(match[1]);
    if (!key) continue;
    assert.equal(result.has(key), false, 'duplicate message: ' + key);
    result.set(key, JSON.parse(match[2]));
  }
  return result;
}

test('every LuCI message has an English template entry and a Russian translation', () => {
  const ids = new Set([...source.matchAll(/_\('((?:\\.|[^'\\])*)'\)/g)].map(match => match[1]));
  const ru = entries(russian);
  const pot = entries(template);
  assert.ok(ids.size >= 70);
  assert.deepEqual([...ru.keys()].sort(), [...ids].sort());
  assert.deepEqual([...pot.keys()].sort(), [...ids].sort());
  for (const id of ids) {
    assert.ok(ru.get(id).trim(), 'missing Russian translation: ' + id);
    assert.equal(pot.get(id), '');
    assert.equal((ru.get(id).match(/%s/g) || []).length, (id.match(/%s/g) || []).length, 'placeholder mismatch: ' + id);
  }
});

test('catalog metadata is UTF-8 and the UI does not force Russian text or locale', () => {
  assert.match(russian, /Language: ru\\n/);
  assert.match(russian, /charset=UTF-8/);
  assert.match(russian, /Plural-Forms: nplurals=3/);
  assert.doesNotMatch(source, /[А-Яа-яЁё]|ru-RU/);
  assert.match(source, /document\.documentElement\.lang/);
});
