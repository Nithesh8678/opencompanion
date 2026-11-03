async (page) => {
  const checks = [];
  const assert = (value, label) => { if (!value) throw new Error(label); checks.push(label); };
  const install = async () => {
    await page.evaluate(() => {
      window.chrome = {runtime: {id: 'bridge-fixture', onMessage: {addListener(listener) { window.__bridgeListener = listener; }}}};
      window.bridgeCommand = (operation, payload = {}) => new Promise((resolve) => window.__bridgeListener({type: 'opencompanion.command', operation, payload}, {id: 'bridge-fixture'}, resolve));
    });
    await page.addScriptTag({path: 'BrowserExtension/content.js'});
  };
  await page.goto('about:blank');
  await page.setContent('<!doctype html><title>Bridge acceptance</title><style>body{font:18px sans-serif;padding:30px}button,input{display:block;margin:20px;padding:12px}#covered{position:relative}#cover{position:fixed;inset:0;background:white;z-index:999;display:none}</style><h1>Meaningful form</h1><label>Name<input id="name" aria-label="Name"></label><input id="password" type="password" aria-label="Password" value="DO-NOT-EXPOSE"><button id="save">Save note</button><p id="result">No saved note</p><button id="covered">Covered target</button><div id="shadow"></div><div id="cover"></div>');
  await page.evaluate(() => { document.querySelector('#save').onclick = () => { document.querySelector('#result').textContent = 'Saved: ' + document.querySelector('#name').value; }; const root = document.querySelector('#shadow').attachShadow({mode: 'open'}); root.innerHTML = '<button aria-label="Shadow action">Shadow action</button>'; });
  await install();
  let snapshot = await page.evaluate(() => bridgeCommand('snapshot'));
  assert(snapshot.ok, 'snapshot succeeds in Chromium');
  let state = snapshot.result;
  assert(state.elements.some((item) => item.name === 'Shadow action'), 'open shadow root semantic target is discovered');
  assert(state.viewport.dpr > 0 && state.coordinateSpace === 'viewportCSSPixels', 'viewport CSS transform metadata is present');
  assert(!JSON.stringify(state).includes('DO-NOT-EXPOSE'), 'password content is excluded');
  const field = state.elements.find((item) => item.name === 'Name' && item.role === 'textbox');
  const filled = await page.evaluate(({state, ref}) => bridgeCommand('act', {documentID: state.documentID, revision: state.revision, ref, kind: 'fill', value: 'OpenCompanion'}), {state, ref: field.ref});
  assert(filled.ok && filled.result.snapshot.elements.some((item) => item.ref === field.ref && item.value === 'OpenCompanion'), 'fill keeps stable refs and returns actual fresh value');
  const stale = await page.evaluate(({state, ref}) => bridgeCommand('act', {documentID: state.documentID, revision: state.revision, ref, kind: 'fill', value: 'stale'}), {state, ref: field.ref});
  assert(!stale.ok && stale.error.includes('Stale'), 'stale revisions are rejected before dispatch');
  state = (await page.evaluate(() => bridgeCommand('snapshot'))).result;
  const save = state.elements.find((item) => item.name === 'Save note');
  const clicked = await page.evaluate(({state, ref}) => bridgeCommand('act', {documentID: state.documentID, revision: state.revision, ref, kind: 'click'}), {state, ref: save.ref});
  assert(clicked.ok && clicked.result.snapshot.text.includes('Saved: OpenCompanion'), 'click returns observed post-action page text');
  assert(clicked.result.action.dispatched && !clicked.result.action.verified, 'dispatch is kept separate from verified task completion');
  await page.evaluate(() => { document.querySelector('#cover').style.display = 'block'; });
  state = (await page.evaluate(() => bridgeCommand('snapshot'))).result;
  const covered = state.elements.find((item) => item.name === 'Covered target');
  const blocked = await page.evaluate(({state, ref}) => bridgeCommand('act', {documentID: state.documentID, revision: state.revision, ref, kind: 'click'}), {state, ref: covered.ref});
  assert(!blocked.ok && blocked.error.includes('covered'), 'covered targets are blocked by current hit testing');
  const previousID = state.documentID;
  await page.goto('about:blank'); await page.setContent('<h1>New document</h1><button>New action</button>'); await install();
  state = (await page.evaluate(() => bridgeCommand('snapshot'))).result;
  assert(state.documentID !== previousID, 'navigation produces a new document scope');
  return {passed: checks.length, checks};
}
