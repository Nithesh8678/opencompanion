import test from 'node:test';
import assert from 'node:assert/strict';

const event = () => ({listeners: [], addListener(listener) { this.listeners.push(listener); }, removeListener(listener) { this.listeners = this.listeners.filter((item) => item !== listener); }});
const native = {onMessage: event(), onDisconnect: event(), sent: [], postMessage(message) { this.sent.push(message); }, disconnect() { for (const listener of this.onDisconnect.listeners) listener(); }};
const runtimeMessages = event();
const tab = {id: 42, windowId: 1, url: 'https://example.com/form', title: 'Fixture'};
let dispatches = 0;
globalThis.chrome = {
  runtime: {id: 'fixture', lastError: null, onMessage: runtimeMessages, connectNative: () => native, getURL: (path) => `chrome-extension://fixture/${path}`},
  storage: {session: {get: async () => ({tabs: []}), set: async () => {}}},
  scripting: {executeScript: async () => []},
  tabs: {get: async () => tab, query: async () => [tab], sendMessage: async () => { dispatches += 1; return {ok: true, result: {documentID: 'fixture', revision: 1}}; }, onRemoved: event(), onUpdated: event()}
};
await import('./service-worker.js');
const popup = (message, sender = {id: 'fixture', url: 'chrome-extension://fixture/popup.html'}) => new Promise((resolve) => {
  const handled = runtimeMessages.listeners[0](message, sender, resolve);
  if (!handled) resolve(undefined);
});
const request = async (message) => {
  const before = native.sent.length;
  native.onMessage.listeners[0](message);
  for (let i = 0; i < 20; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 5));
    const result = native.sent.slice(before).find((item) => item.type === 'browser.result');
    if (result) return result;
  }
  throw new Error('Timed out waiting for fixture response.');
};
test('MV3 bridge enforces popup scope, read-only tabs, origin lifetime and stop', async () => {
  const denied = await popup({type: 'popup.connect', tabID: 42}, {id: 'fixture', tab: {id: 42}, url: 'https://example.com/'});
  assert.equal(denied, undefined);
  assert.equal((await popup({type: 'popup.connect', tabID: 42, allowActions: false})).ok, true);
  assert.equal(native.sent[0].type, 'browser.hello');
  assert.equal(native.sent[0].tabs[0].allowActions, false);
  const base = {protocolVersion: 1, type: 'browser.request', requestID: 'fixture-1', tabID: 42};
  assert.equal((await request({...base, operation: 'snapshot'})).ok, true);
  const before = dispatches;
  const write = await request({...base, operation: 'act', payload: {kind: 'click'}});
  assert.equal(write.ok, false);
  assert.match(write.error.message, /read only/);
  assert.equal(dispatches, before);
  const elsewhere = await request({...base, operation: 'snapshot', tabID: 99});
  assert.equal(elsewhere.ok, false);
  assert.match(elsewhere.error.message, /not connected/);
  tab.url = 'https://different.example/';
  const changed = await request({...base, operation: 'snapshot'});
  assert.equal(changed.ok, false);
  assert.match(changed.error.message, /changed origin/);
  await popup({type: 'popup.stop'});
  assert.deepEqual((await popup({type: 'popup.status'})).tabs, []);
});
