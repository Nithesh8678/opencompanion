# Architecture

OpenCompanion is independently implemented Swift6 code. It uses Apple frameworks and SQLite, with no proprietary drawing source, assets, service endpoints or identities.

The native app owns permission prompts, window roles, selected context, local presentation and observed action results. CompanionCore owns bounded scene documents, typed expressions, atomic transactions, event ordering/generations, coordinate transforms and guidance/beat state. CompanionStore owns migrated SQLite content, leases, checkpoints, receipts and explicit memory. The browser extension grants one tab at a time and the native host bridges bounded framed messages over an owner-only Unix socket.

Reasoning uses either the documented local Codex app-server with its managed ChatGPT login, or a configurable OpenAI-compatible HTTP/SSE provider. Provider output is complete NDJSON teaching units; incomplete JSON remains data. The host validates nodes and retains earlier useful content on later failures. Model text cannot invoke native methods or grant action scope. Browser and desktop write controls are explicit UI actions.

Independent clocks:

- Reasoning emits complete units; no frame-by-frame model calls.
- Retained native layers and cached procedural geometry animate locally.
- Apple speech synthesizer delegate events report only their actual meaning. The tested core beat clock can release speech-synchronized or text-only beats; complete application audio-reveal synchronization remains a tracked integration gap.

Cancellation advances the application generation before cancelling tasks/playback/annotations. Notebook revisions and desktop perception revisions are distinct. A current notebook does not validate an old desktop rectangle. Job leases prevent concurrent ownership; interrupted non-idempotent effects become outcomeUnknown, requiring observation before replay.

Provider adapters currently consume an app-specific compact teaching-unit protocol, rather than accepting every event in the full stream/1 specification. CompanionCore includes the broader typed envelope and transaction validation for incremental integration. See FEATURE-STATUS.md for remaining implementation and acceptance.
