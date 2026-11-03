# Engineering standards

Use Swift 6 strict concurrency. Keep IO and expensive work away from render/audio callbacks. Validate untrusted model/tool/file data, bound allocations, preserve task generations and document revisions independently, and report observed outcomes. Credentials stay in Keychain. Do not commit user content, captures, credentials, build outputs, or proprietary research assets. Run focused tests and compile the app before publishing a checkpoint. Keep docs/FEATURE-STATUS.md evidence based.

Keep one installed app at `/Applications/OpenCompanion.app`. After app changes, build with `scripts/build-app.sh` and replace it with `scripts/install.sh`; never create versioned app copies or backup bundles in Applications. Quit the app through its UI before replacing it, preserve user data, and verify the installed receipt. Generated build apps are temporary and the installer cleans them up.
