# Contributing

Start with docs/FEATURE-STATUS.md and choose one tracked gap. Small complete vertical changes with observed behavior are preferred. Use Swift6 concurrency checks and keep user content/secrets out of the repository. Do not add network/AX/OCR/geometry work to render or audio callbacks. Keep OS support availability-gated and add meaningful tests for protocol, transforms, revisions, cancellation and persistence.

Run `swift test`, the Python/browser checks documented in their folders, and `scripts/build-app.sh`. Test new user-facing behavior in the real .app and record what was exercised. Include setup, expected results and exact limitations in the PR. No proprietary assets/source or unsupported parity/performance claims.
