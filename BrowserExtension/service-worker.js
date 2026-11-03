import {validateRequest, scopedNavigation, MAX_MESSAGE_BYTES} from './protocol.mjs';
const HOST = 'org.opencompanion.browser';
let port = null;
let lastError = '';
let generation = 0;
let pending = 0;
let requestTail = Promise.resolve();
const connected = new Map();
const restored = chrome.storage.session.get('tabs').then(({tabs = []}) => { for (const item of tabs) connected.set(item.tabID, item); });
function report(message) {
  if (!port) return;
  if (new TextEncoder().encode(JSON.stringify(message)).length >= MAX_MESSAGE_BYTES) throw new Error('Browser result exceeds the 1 MiB transport limit.');
  port.postMessage(message);
}
async function persist() { await chrome.storage.session.set({tabs: [...connected.values()]}); }
function hello() { report({protocolVersion: 1, type: 'browser.hello', connectionID: crypto.randomUUID(), extensionID: chrome.runtime.id, capabilities: ['snapshot', 'act', 'navigate', 'capture'], tabs: [...connected.values()]}); }
function connectHost() {
  if (port) return;
  lastError = '';
  const current = chrome.runtime.connectNative(HOST);
  port = current;
  current.onDisconnect.addListener(() => {
    lastError = chrome.runtime.lastError?.message || 'The local browser host disconnected.';
    if (port === current) port = null;
    generation += 1;
  });
  current.onMessage.addListener((message) => {
    if (message?.type === 'browser.error') { lastError = String(message.error || 'Local host error.'); current.disconnect(); if (port === current) port = null; generation += 1; return; }
    const requestGeneration = generation;
    if (pending >= 4) { report({protocolVersion: 1, type: 'browser.result', requestID: message.requestID, ok: false, error: {code: 'busy', message: 'Browser queue is full.'}}); return; }
    pending += 1;
    requestTail = requestTail.then(async () => {
      try {
        validateRequest(message);
        if (requestGeneration !== generation) throw new Error('Request cancelled.');
        const result = await perform(message, requestGeneration);
        if (message.operation !== 'stop' && requestGeneration !== generation) throw new Error('Result cancelled; an action already dispatched may have an unknown outcome.');
        report({protocolVersion: 1, type: 'browser.result', requestID: message.requestID, ok: true, result});
      } catch (error) {
        report({protocolVersion: 1, type: 'browser.result', requestID: message.requestID || 'invalid', ok: false, error: {code: 'browser_error', message: String(error.message || error)}});
      } finally { pending -= 1; }
    }).catch(() => { /* A closed native port invalidates the queue via onDisconnect. */ });
  });
  hello();
}
async function scope(tabID, actions = false) {
  const item = connected.get(tabID);
  if (!item) throw new Error('This tab is not connected. Use the extension popup.');
  if (actions && !item.allowActions) throw new Error('This tab is read only. Allow actions in the extension popup.');
  const tab = await chrome.tabs.get(tabID);
  if (!tab.url || new URL(tab.url).origin !== item.origin) {
    connected.delete(tabID); await persist(); throw new Error('The tab changed origin. Reconnect it explicitly.');
  }
  return {item, tab};
}
async function content(tabID, operation, payload, requestGeneration) {
  await chrome.scripting.executeScript({target: {tabId: tabID}, files: ['content.js']});
  if (requestGeneration !== generation) throw new Error('Request cancelled before content dispatch.');
  const result = await chrome.tabs.sendMessage(tabID, {type: 'opencompanion.command', operation, payload});
  if (!result?.ok) throw new Error(result?.error || 'Content bridge is unavailable.');
  return result.result;
}
async function perform(request, requestGeneration) {
  const {operation, tabID, payload = {}} = request;
  if (operation === 'stop') { generation += 1; for (const id of connected.keys()) chrome.tabs.sendMessage(id, {type: 'opencompanion.stop'}).catch(() => {}); return {stopped: true}; }
  const {tab, item} = await scope(tabID, ['act', 'navigate'].includes(operation));
  if (operation === 'snapshot' || operation === 'act') return content(tabID, operation, payload, requestGeneration);
  if (operation === 'capture') {
    const [active] = await chrome.tabs.query({active: true, windowId: tab.windowId});
    if (active?.id !== tabID) throw new Error('Capture requires the connected tab to be active.');
    const before = await content(tabID, 'snapshot', {}, requestGeneration);
    const image = await chrome.tabs.captureVisibleTab(tab.windowId, {format: 'jpeg', quality: 45});
    const [afterActive] = await chrome.tabs.query({active: true, windowId: tab.windowId});
    const after = await content(tabID, 'snapshot', {}, requestGeneration);
    if (afterActive?.id !== tabID || before.documentID !== after.documentID || before.revision !== after.revision) throw new Error('The page changed during capture. Request fresh evidence.');
    if (image.length > 850000) throw new Error('Capture exceeds the bridge budget. Use a smaller viewport.');
    return {image, imageFormat: 'jpeg', coordinateSpace: 'viewportCSSPixels', snapshot: after};
  }
  if (operation === 'navigate') {
    const url = scopedNavigation(payload.url, item.origin);
    await new Promise((resolve, reject) => {
      let timer;
      const listener = (id, change) => { if (id === tabID && change.status === 'complete') { cleanup(); resolve(); } };
      function cleanup() { clearTimeout(timer); chrome.tabs.onUpdated.removeListener(listener); }
      chrome.tabs.onUpdated.addListener(listener);
      timer = setTimeout(() => { cleanup(); reject(new Error('Navigation did not settle within 8 seconds; request a fresh snapshot before retrying.')); }, 8000);
      chrome.tabs.update(tabID, {url}).catch((error) => { cleanup(); reject(error); });
    });
    await scope(tabID);
    return {dispatched: true, verified: false, snapshot: await content(tabID, 'snapshot', {}, requestGeneration)};
  }
  throw new Error('Unsupported operation.');
}
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  // Content pages cannot request scope expansion or native commands.
  if (sender.id !== chrome.runtime.id || sender.tab || !sender.url?.startsWith(chrome.runtime.getURL('popup.html'))) return false;
  (async () => {
    await restored;
    if (message.type === 'popup.status') return {ok: true, tabs: [...connected.values()], nativeConnected: !!port, error: lastError};
    if (message.type === 'popup.connect') {
      const tab = await chrome.tabs.get(message.tabID);
      if (!/^https?:\/\//.test(tab.url || '')) throw new Error('Connect a regular HTTP(S) page. Browser internal pages are protected.');
      await chrome.scripting.executeScript({target: {tabId: tab.id}, files: ['content.js']});
      connected.set(tab.id, {tabID: tab.id, title: tab.title || '', url: tab.url, origin: new URL(tab.url).origin, allowActions: message.allowActions === true});
      await persist(); connectHost(); hello(); return {ok: true};
    }
    if (message.type === 'popup.disconnect') {
      connected.delete(message.tabID); generation += 1; await chrome.tabs.sendMessage(message.tabID, {type: 'opencompanion.stop'}).catch(() => {}); await persist(); hello(); return {ok: true};
    }
    if (message.type === 'popup.stop') {
      generation += 1;
      for (const id of connected.keys()) chrome.tabs.sendMessage(id, {type: 'opencompanion.stop'}).catch(() => {});
      connected.clear(); await persist(); hello(); port?.disconnect(); port = null; return {ok: true};
    }
    throw new Error('Unsupported popup message.');
  })().then(sendResponse, (error) => sendResponse({ok: false, error: error.message}));
  return true;
});
chrome.tabs.onRemoved.addListener(async (tabID) => { await restored; if (connected.delete(tabID)) { generation += 1; await persist(); hello(); } });
chrome.tabs.onUpdated.addListener(async (tabID, change, tab) => {
  await restored;
  const item = connected.get(tabID);
  if (item && change.url && new URL(change.url).origin !== item.origin) { connected.delete(tabID); generation += 1; await persist(); hello(); }
});
