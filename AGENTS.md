# Engineering standards

Use Swift 6 strict concurrency. Keep IO and expensive work away from render/audio callbacks. Validate untrusted model/tool/file data, bound allocations, preserve task generations and document revisions independently, and report observed outcomes. Credentials stay in Keychain. Do not commit user content, captures, credentials, build outputs, or proprietary research assets. Run focused tests and compile the app before publishing a checkpoint. Keep docs/FEATURE-STATUS.md evidence based.

Local app updates must reuse the existing ignored `build/local-signing.json` identity/team when present. Do not silently switch an installed certificate-signed local app back to ad-hoc signing: that changes its macOS privacy identity. Explicit environment overrides and CI ad-hoc builds remain supported. Never create/trust a certificate or export a private key as part of a routine build. See `docs/LOCAL-SIGNING.md`.

Keep one installed app at `/Applications/OpenCompanion.app`. After app changes, build with `scripts/build-app.sh` and replace it with `scripts/install.sh`; never create versioned app copies or backup bundles in Applications. Quit the app through its UI before replacing it, preserve user data, and verify the installed receipt. Generated build apps are temporary and the installer cleans them up.
