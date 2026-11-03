/* Runs in Chrome's isolated extension world; never evaluates page/model code. */
(() => {
  'use strict';
  if (globalThis.__openCompanionBridge) return;
  globalThis.__openCompanionBridge = true;
  const documentID = Array.from(crypto.getRandomValues(new Uint8Array(16)), (byte) => byte.toString(16).padStart(2, '0')).join('');
  let revision = 1;
  let nextRef = 0;
  let cancellation = 0;
  let records = new Map();
  const ids = new WeakMap();
  const observers = new Map();
  const selector = 'a[href],button,input,textarea,select,summary,[role],[contenteditable="true"],h1,h2,h3,h4,img,iframe';
  function observe(root) {
    if (observers.has(root) || observers.size >= 64) return;
    const observer = new MutationObserver(() => { revision += 1; });
    observer.observe(root, {subtree: true, childList: true, attributes: true, characterData: true});
    observers.set(root, observer);
  }
  function flush() { for (const observer of observers.values()) if (observer.takeRecords().length) revision += 1; }
  observe(document);
  for (const event of ['input', 'change', 'scroll', 'resize', 'load', 'popstate', 'hashchange']) addEventListener(event, () => { revision += 1; }, {capture: true, passive: true});
  const clean = (value, limit = 240) => String(value || '').replace(/\s+/g, ' ').trim().slice(0, limit);
  const protectedField = (element) => ['password', 'file', 'hidden'].includes(String(element.type || '').toLowerCase()) || /password|cc-|one-time-code/.test(element.autocomplete || '');
  function visible(element) {
    const rect = element.getBoundingClientRect();
    const style = element.ownerDocument.defaultView.getComputedStyle(element);
    return element.isConnected && style.display !== 'none' && style.visibility !== 'hidden' && Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
  }
  function role(element) {
    return element.getAttribute('role') || ({A: 'link', BUTTON: 'button', INPUT: element.type === 'checkbox' ? 'checkbox' : element.type === 'radio' ? 'radio' : 'textbox', TEXTAREA: 'textbox', SELECT: 'combobox', IMG: 'image', SUMMARY: 'button', IFRAME: 'frame'}[element.tagName]) || (/^H[1-6]$/.test(element.tagName) ? 'heading' : 'generic');
  }
  function name(element) {
    const labelled = (element.getAttribute('aria-labelledby') || '').split(/\s+/).map((id) => element.ownerDocument.getElementById(id)?.textContent || '').join(' ');
    return clean(element.getAttribute('aria-label') || labelled || Array.from(element.labels || []).map((label) => label.textContent).join(' ') || element.getAttribute('alt') || element.getAttribute('title') || element.getAttribute('placeholder') || element.textContent);
  }
  function snapshot() {
    for (const [root, observer] of observers) {
      if (root === document) continue;
      let attached = false;
      try { attached = root.host ? root.host.isConnected : root.defaultView?.document === root && !!root.defaultView?.frameElement?.isConnected; } catch { /* detached or opaque */ }
      if (!attached) { observer.disconnect(); observers.delete(root); revision += 1; }
    }
    flush();
    const elements = [];
    const text = [];
    const frames = [];
    records = new Map();
    let visited = 0;
    let textLength = 0;
    let truncated = false;
    function visit(root, offsetX = 0, offsetY = 0, frameElement = null, depth = 0) {
      if (depth > 12 || visited >= 20000) { truncated = true; return; }
      observe(root);
      const doc = root.ownerDocument || root;
      const walker = doc.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode())) {
        if (++visited > 20000) { truncated = true; break; }
        if (node.nodeType === Node.TEXT_NODE) {
          if (textLength < 32000 && node.parentElement && !node.parentElement.closest('script,style,noscript,textarea,[aria-hidden="true"]') && visible(node.parentElement)) {
            const value = clean(node.textContent, Math.min(1000, 32000 - textLength));
            if (value) { text.push(value); textLength += value.length; }
          }
          continue;
        }
        const element = node;
        if (element.shadowRoot) visit(element.shadowRoot, offsetX, offsetY, frameElement, depth + 1);
        if (element.tagName === 'IFRAME') {
          const rect = element.getBoundingClientRect();
          try {
            const child = element.contentDocument;
            // Scaled/transformed nested browsing contexts require a richer coordinate chain.
            if (child && Math.abs(rect.width - element.offsetWidth) < 1 && Math.abs(rect.height - element.offsetHeight) < 1) {
              frames.push({accessible: true, rect: {x: rect.x + offsetX, y: rect.y + offsetY, width: rect.width, height: rect.height}});
              visit(child, offsetX + rect.x + element.clientLeft, offsetY + rect.y + element.clientTop, element, depth + 1);
            } else frames.push({accessible: false, reason: 'cross-origin or transformed frame'});
          } catch { frames.push({accessible: false, reason: 'cross-origin frame'}); }
        }
        if (!element.matches(selector) || !visible(element) || elements.length >= 400) continue;
        const rect = element.getBoundingClientRect();
        const box = {x: rect.x + offsetX, y: rect.y + offsetY, width: rect.width, height: rect.height};
        if (box.x + box.width <= 0 || box.y + box.height <= 0 || box.x >= innerWidth || box.y >= innerHeight) continue;
        if (!ids.has(element)) ids.set(element, `${documentID}:${++nextRef}`);
        const ref = ids.get(element);
        records.set(ref, {element, offsetX, offsetY, frameElement});
        const entry = {ref, role: role(element), name: name(element), rect: box, disabled: !!element.disabled, protected: protectedField(element)};
        if ('value' in element && !entry.protected) entry.value = clean(element.value, 2000);
        if ('checked' in element) entry.checked = !!element.checked;
        elements.push(entry);
      }
    }
    visit(document);
    flush();
    return {documentID, revision, url: location.href, title: document.title, coordinateSpace: 'viewportCSSPixels', viewport: {width: innerWidth, height: innerHeight, dpr: devicePixelRatio, scrollX, scrollY, visualScale: visualViewport?.scale || 1, visualOffsetX: visualViewport?.offsetLeft || 0, visualOffsetY: visualViewport?.offsetTop || 0}, elements, text: text.join('\n'), frames, truncated: truncated || elements.length === 400 || textLength >= 32000, limitations: ['Closed shadow roots and cross-origin frames are opaque.', 'A dispatched DOM action is not a verified task result.']};
  }
  function composedContains(element, hit) {
    while (hit) { if (hit === element || element.contains(hit)) return true; hit = hit.getRootNode()?.host; }
    return false;
  }
  function hitTarget(record) {
    const {element, offsetX, offsetY, frameElement} = record;
    if (!visible(element) || element.disabled || element.getAttribute('aria-disabled') === 'true') throw new Error('Target is detached, hidden or disabled.');
    const rect = element.getBoundingClientRect();
    const x = Math.max(0, Math.min(innerWidth - offsetX, rect.right) - Math.max(-offsetX, rect.left));
    const y = Math.max(0, Math.min(innerHeight - offsetY, rect.bottom) - Math.max(-offsetY, rect.top));
    if (x <= 0 || y <= 0) throw new Error('Target is outside the viewport. Take a new snapshot after scrolling.');
    const pointX = Math.max(-offsetX, rect.left) + x / 2;
    const pointY = Math.max(-offsetY, rect.top) + y / 2;
    const root = element.getRootNode();
    const hit = root.elementFromPoint?.(pointX, pointY) || element.ownerDocument.elementFromPoint(pointX, pointY);
    if (!composedContains(element, hit)) throw new Error('Target is covered by another element.');
    if (frameElement) {
      const topHit = document.elementFromPoint(pointX + offsetX, pointY + offsetY);
      if (topHit !== frameElement && !composedContains(frameElement, topHit)) throw new Error('Frame is covered.');
    }
  }
  async function settle(startCancellation) {
    const start = performance.now();
    let quietSince = start;
    let lastRevision = revision;
    while (performance.now() - start < 650) {
      await new Promise((resolve) => setTimeout(resolve, 40));
      if (startCancellation !== cancellation) throw new Error('Action cancelled after dispatch; inspect the page before retrying.');
      flush();
      if (revision !== lastRevision) { lastRevision = revision; quietSince = performance.now(); }
      if (performance.now() - quietSince >= 120) return {quiet: true, elapsedMS: Math.round(performance.now() - start)};
    }
    return {quiet: false, elapsedMS: Math.round(performance.now() - start)};
  }
  async function act(payload) {
    flush();
    if (payload.documentID !== documentID || payload.revision !== revision) throw new Error('Stale document or scene revision. Request a fresh snapshot.');
    if (typeof payload.ref !== 'string' || !payload.ref.startsWith(`${documentID}:`)) throw new Error('Reference belongs to another document.');
    const record = records.get(payload.ref);
    if (!record) throw new Error('Reference is absent from the last snapshot.');
    const {element} = record;
    if (protectedField(element)) throw new Error('Protected fields require direct user input.');
    hitTarget(record);
    const startCancellation = cancellation;
    const kind = payload.kind;
    if (kind === 'click') element.click();
    else if (kind === 'fill') {
      if (!['INPUT', 'TEXTAREA'].includes(element.tagName)) throw new Error('Fill supports ordinary text inputs and textareas.');
      if (element.readOnly || !['text', 'search', 'email', 'url', 'tel', 'number', 'textarea', ''].includes(element.type)) throw new Error('This field is not a writable text field.');
      if (typeof payload.value !== 'string' || payload.value.length > 12000) throw new Error('Fill value exceeds the text budget.');
      element.focus({preventScroll: true});
      if (element.ownerDocument.activeElement !== element && element.getRootNode().activeElement !== element) throw new Error('Typing focus could not be verified.');
      const owner = element.ownerDocument.defaultView;
      const prototype = element.tagName === 'TEXTAREA' ? owner.HTMLTextAreaElement.prototype : owner.HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(prototype, 'value').set.call(element, payload.value);
      element.dispatchEvent(new owner.Event('input', {bubbles: true}));
      element.dispatchEvent(new owner.Event('change', {bubbles: true}));
    } else if (kind === 'select') {
      if (element.tagName !== 'SELECT' || typeof payload.value !== 'string' || !Array.from(element.options).some((option) => option.value === payload.value && !option.disabled)) throw new Error('Select requires an enabled existing option.');
      element.value = payload.value; element.dispatchEvent(new Event('change', {bubbles: true}));
    } else if (kind === 'scroll') {
      const dx = Number(payload.deltaX || 0), dy = Number(payload.deltaY || 0);
      if (!Number.isFinite(dx) || !Number.isFinite(dy) || Math.abs(dx) > 2000 || Math.abs(dy) > 2000) throw new Error('Scroll exceeds the action budget.');
      element.scrollBy({left: dx, top: dy, behavior: 'instant'});
    } else throw new Error('Unsupported action.');
    revision += 1;
    const settling = await settle(startCancellation);
    return {action: {kind, ref: payload.ref, dispatched: true, verified: false, outcome: 'observationRequired'}, settling, snapshot: snapshot()};
  }
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (sender.id !== chrome.runtime.id) return false;
    if (message.type === 'opencompanion.stop') { cancellation += 1; revision += 1; sendResponse({ok: true}); return false; }
    if (message.type !== 'opencompanion.command') return false;
    Promise.resolve().then(() => {
      if (message.operation === 'snapshot') return snapshot();
      if (message.operation === 'act') return act(message.payload || {});
      throw new Error('Unsupported content operation.');
    }).then((result) => sendResponse({ok: true, result}), (error) => sendResponse({ok: false, error: error.message}));
    return true;
  });
})();
