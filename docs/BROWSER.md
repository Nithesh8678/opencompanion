# Browser bridge

The original MV3 extension exposes only tabs the user explicitly connects. It has no `<all_urls>` permission. The Mac app, native host and extension are independently owned OpenCompanion components; they do not use another product's identities or servers.

## Setup on macOS

1. Build/open the app. In Connections → Browser, start its local bridge.
2. Open Chrome's `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and select the repository's `BrowserExtension/` directory. Edge and Chromium have their corresponding extension managers; their installers are provided but have not been installed-tested here.
3. Copy the displayed 32-letter extension ID. From the repository, run:

   ```sh
   python3 NativeBrowserHost/install.py --extension-id YOUR_EXTENSION_ID --browser chrome
   ```

4. Visit a normal HTTP(S) page, click the OpenCompanion toolbar icon and **Connect this tab**. Read access is the default. Enable the action checkbox only when clicks/typing/navigation are intended.
5. The app's status changes to Connected only after receiving a real extension handshake. Read a fresh snapshot before selecting a target. Keep a browser tab active for screenshots.

Python 3 is a host prerequisite. The installer records the exact Python executable used at install time in a shell launcher; reinstall if that Python moves. It installs only for the current user, needs no sudo, and pins the exact extension ID without wildcards. Restart/reconnect after changing host files or permissions.

Stop all browser work from the extension popup or stop the app bridge. A tab changing to a different origin loses its scope and must be connected again. A same-origin navigation creates a new document identity, so prior refs must be discarded. Protected browser pages cannot be injected. Stop invalidates queued requests; it cannot undo a click that already happened.

## Repair and removal

If disconnected, open the app, start the bridge and reconnect the tab. Check that the extension ID matches `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/org.opencompanion.browser.json`. Browser-host diagnostics go to stderr; browser contents are never logged by the host. A stale/dead app socket is replaced only if user-owned; an active second app instance is rejected.

```sh
python3 NativeBrowserHost/install.py --uninstall --browser chrome
```

Remove the unpacked extension from the extension manager. The installer leaves shared host files at `~/Library/Application Support/OpenCompanion/NativeBrowserHost/` because other browser registrations can share them. After removing all Chrome/Chromium/Edge registrations, that directory can be deleted manually. The app's documents/history directory is separate and is not deleted.

## Transport and capabilities

Native host ID: `org.opencompanion.browser`. The app owns `~/Library/Application Support/OpenCompanion/browser.sock`, a Unix socket mode 0600 in its mode-0700 directory. The Swift app verifies the peer UID. The Python host checks socket ownership/mode and forwards duplex JSON without persisting it. Native messaging uses native-endian 32-bit length-prefixed UTF-8; the local socket uses one compact JSON object per line. Both directions are bounded below 1 MiB. App/native queues allow at most four pending requests.

Extension handshake:

```json
{"protocolVersion":1,"type":"browser.hello","connectionID":"...","extensionID":"...","capabilities":["snapshot","act","navigate","capture"],"tabs":[{"tabID":42,"title":"Example","url":"https://example.com/","origin":"https://example.com","allowActions":false}]}
```

App request:

```json
{"protocolVersion":1,"type":"browser.request","requestID":"unique-request-id","operation":"snapshot","tabID":42,"payload":{}}
```

Results carry the same requestID with `type: browser.result`, `ok` and `result` or `error`. `snapshot` returns a random documentID, monotonic revision, bounded visible semantic elements/text, viewport CSS-pixel bounds, DPR, visual viewport metadata, frame visibility and truncation flags. Refs survive retained elements within a document. Open shadow roots and same-origin untransformed frames are traversed; cross-origin/closed roots are opaque. Nested/transformed-frame actions can be rejected; they are not a supported pixel-action fallback.

`act` requires `{documentID, revision, ref, kind, ...}`. Supported kinds: `click`, `fill` with string `value`, `select` with an existing option `value`, `scroll` with finite `deltaX`/`deltaY` bounded to 2,000 CSS pixels. The executor checks current revision, attachment, enabled state, viewport and current hit-testing immediately before dispatch. Fill checks actual focus and blocks password/file/hidden/payment/OTP fields. No model JavaScript or arbitrary code is accepted.

Every successful action returns an action receipt plus a newly collected snapshot after a bounded quiet period (120 ms quiet, maximum 650 ms). `dispatched: true, verified: false` means exactly that. The caller must compare a requested URL/value/dialog/document postcondition. A fresh snapshot is evidence, not automatic proof that a business task completed. There are no blind retries of actions. Browsers can reject synthetic DOM actions requiring trusted user input; those need direct user interaction.

`navigate` is limited to the connected HTTP(S) origin and settles for at most 8 seconds; another origin needs a manual reconnect. `capture` captures only an active connected tab as bounded JPEG and rejects tab/revision changes during capture. Its image and CSS viewport metadata are returned together. A requested `stop` invalidates queued work; the popup stop also disconnects every tab/native port.

## Verification

```sh
node --test BrowserExtension/test_*.mjs
python3 -m unittest discover -s NativeBrowserHost -p 'test_*.py' -v
```

`BrowserExtension/tests/dom-acceptance.js` is a Playwright CLI `run-code --filename` fixture. Run it from the repository root in an isolated Chromium session. It exercises the actual content script in real DOM with mocked extension messaging; it does not install the MV3 package or prove native-host registration. Ten assertions passed: snapshot, shadow refs, CSS transforms, protected-value exclusion, fill/stable refs, stale rejection, click/result observation, no false task completion, covered-target rejection and document lifetime. Node tests cover service-worker scope/read-only/origin/stop and request validation. Python tests cover framing, malformed/partial/budget rejection, socket permissions and a real subprocess/socket duplex exchange. A separate macOS Swift smoke test passed through the actual app listener, Unix socket, native-host subprocess and native framing, including a true hello and snapshot result; Chrome framing is simulated by the peer fixture. Reproduce it with:

```sh
swiftc -swift-version 6 Sources/OpenCompanion/BrowserBridge.swift NativeBrowserHost/tests/AppBridgeSmoke.swift -o /tmp/opencompanion-browser-smoke
/tmp/opencompanion-browser-smoke "$(command -v python3)" "$PWD/NativeBrowserHost/tests/native_peer.py"
```


Full installed extension → Chrome native host → installed app acceptance, browser zoom/cross-frame matrices and long sessions remain required before advertising those as installed-tested.

Chrome platform contracts: [native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [activeTab](https://developer.chrome.com/docs/extensions/develop/concepts/activeTab).
