'use strict';
const status = document.querySelector('#status');
let tabID;
async function refresh() {
  const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
  tabID = tab?.id;
  document.querySelector('#tab').textContent = tab?.title || 'No accessible tab';
  const state = await chrome.runtime.sendMessage({type: 'popup.status'});
  const connection = state.tabs.find((item) => item.tabID === tabID);
  document.querySelector('#actions').checked = connection?.allowActions || false;
  status.textContent = connection && state.nativeConnected ? `Connected · ${connection.allowActions ? 'actions allowed' : 'read only'}` : state.error || 'Disconnected. Open the local app, then connect this tab.';
}
for (const name of ['connect', 'disconnect', 'stop']) {
  document.querySelector(`#${name}`).addEventListener('click', async () => {
    const button = document.querySelector(`#${name}`);
    button.disabled = true;
    try {
      const result = await chrome.runtime.sendMessage({type: `popup.${name}`, tabID, allowActions: document.querySelector('#actions').checked});
      if (!result.ok) throw new Error(result.error);
      await refresh();
      if (name === 'stop') status.textContent = 'Stopped. All tabs disconnected; queued results invalidated.';
    } catch (error) { status.textContent = error.message; }
    finally { button.disabled = false; }
  });
}
refresh().catch((error) => { status.textContent = error.message; });
