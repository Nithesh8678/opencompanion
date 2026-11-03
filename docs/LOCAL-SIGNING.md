# Local signing and macOS permission identity

The default build is ad-hoc signed for CI and local compilation. Its designated requirement contains the executable's changing code hash, so a new build can lose macOS privacy grants even when it replaces the same `/Applications/OpenCompanion.app`. Input Monitoring, Screen Recording, Accessibility, Microphone and Speech Recognition remain controlled by macOS; a successful build or event-tap preflight does not prove physical shortcut delivery.

For repeated local updates, use an existing valid Apple Development or Developer ID Application identity consistently. `scripts/build-app.sh` reads this optional, ignored file:

```json
{
  "identity": "EXISTING_CODE_SIGNING_IDENTITY_SHA1",
  "team": "YOURTEAMID"
}
```

Save it as `build/local-signing.json`, replacing both placeholders with an existing identity's values. The script never creates or trusts a certificate or exports a private key. Xcode/codesign may ask macOS to authorize use of the existing key. Reuse the same identity, bundle identifier and canonical installation path for later updates. The first switch from ad-hoc signing requires fresh permission approval for the newly signed app; subsequent permission retention must still be checked on the installed app.

Explicit `CODE_SIGN_IDENTITY` and `DEVELOPMENT_TEAM` environment values override the local file. `CODE_SIGN_IDENTITY=-` explicitly selects ad-hoc signing. CI ignores the local file and defaults to ad-hoc unless environment settings are provided. Never commit a personal signing configuration or key.

`dist/BUILD-RECEIPT.json` records the actual signature class, signing team, authority chain and designated requirement after verification. Compare the designated requirement across local updates before asking the user to approve privacy permissions again. Developer ID distribution, hardened runtime, notarization and signed updates remain separate release work; an Apple Development certificate is suitable for the local development workflow and does not establish those distribution properties.
