# Self-hosted relay

`Server/server.py` is a working, single-user authenticated OpenAI-compatible HTTP/SSE relay with no third-party Python dependencies. The local app's UI, screen capture, rendering and persistence stay on the Mac. The relay forwards only requests the app submits to its configured provider. It does not provide hosted billing, multi-tenant accounts, a remote desktop, file uploads, remote jobs, STT or TTS endpoints.

The default loopback binding is intentional. Python's standard-library HTTP server is a small deployment component, not an internet-facing production gateway. For a remote server, keep the process on loopback behind a maintained TLS reverse proxy that enforces network access, request/body limits and streaming timeouts. Terminate TLS before forwarding to loopback and disable response buffering for SSE. Operate under a dedicated OS account. Remote-provider connections require HTTPS; plain HTTP is permitted only for a local provider.

## Start

Use Python 3.10 or newer. No virtual environment/packages are required. Set credentials in your shell or service manager, never in source. Generate a strong relay token locally, for example `python3 -c 'import secrets; print(secrets.token_urlsafe(32))'`. Keep the provider key on the relay machine.

```sh
export OPENCOMPANION_RELAY_TOKEN='YOUR_RANDOM_TOKEN_AT_LEAST_32_CHARACTERS'
export OPENCOMPANION_PROVIDER_KEY='YOUR_PROVIDER_KEY'
export OPENCOMPANION_PROVIDER_BASE_URL='https://api.openai.com/v1'
python3 Server/server.py
```

The example file `Server/.env.example` documents all settings; the server does not automatically load `.env` files. `OPENCOMPANION_PORT` defaults to 8736. `OPENCOMPANION_BIND` permits loopback only. A provider-compatible base URL must contain the API prefix (for example `/v1`); the server appends `/chat/completions`. Models are supplied by the client and are never inferred from a catalog or simulated. Choose an entitled model and run the app's real connection test.

In the Mac app's compatible-provider settings, configure base endpoint `http://127.0.0.1:8736/v1` (or your TLS relay's API base path; the app appends `/chat/completions`), your chosen model ID and **the relay token** as the credential. The provider key is not the client credential. The app stores its credential in Keychain. Using a paid inference provider still incurs that provider's costs.

Health:

```sh
curl http://127.0.0.1:8736/health
```

Health reports the relay process and `providerConnectivity: not-tested`. A healthy process does not prove provider/model entitlement. Submit a real request from the app to establish that separately.

## Open interface

- `GET /health`: minimal unauthenticated process health. No credentials or prompt data.
- `POST /v1/chat/completions`: `Authorization: Bearer RELAY_TOKEN`, `Content-Type: application/json`, a configured `model`, nonempty `messages` array, optional boolean `stream`. Ordinary OpenAI-compatible request fields pass through to the configured provider. Optional `X-Request-ID` is a unique 1–128-character identifier containing letters, digits, `_` or `-`; SSE responses return it.
- `POST /v1/cancel`: same authorization and JSON `{ "requestID": "..." }`. This sets cancellation and shuts down the current upstream socket. Cancellation closes the stream and does not reverse already-completed provider/tool side effects. The app can cancel by cancelling its HTTP request; explicit cancel is useful when the client retains a request ID.

The relay has four active provider slots and sixteen HTTP connection slots. Bodies are limited to 1 MiB, SSE lines to 256 KiB, responses/streams to 16 MiB and streaming request duration to 120 seconds. Socket reads/writes have timeouts. Provider bytes are read only as downstream writes complete: there is no unbounded stream queue. Bad credentials fail before any upstream request. Browser-origin requests are rejected; no CORS access is enabled. Provider keys/authorization/prompt bodies are not logged or returned by the relay. There is no persistent database or server-side retention.

On explicit cancellation, the relay interrupts the active upstream socket and returns 499 before response headers, or a bounded error event if streaming has begun. Provider/network errors are visible and never replaced by fixture responses. Cancellation during DNS/connect can depend on the bounded connection timeout. Client disconnect is detected on a subsequent write; if a provider produces no data, the read timeout bounds cleanup.

## Validation and operational limits

```sh
python3 -m unittest discover -s Server -p 'test_*.py' -v
```

Six integration/configuration tests passed against a local mock upstream, including ordinary JSON, SSE, correct server-only key forwarding, authentication, explicit cancellation latency, honest health, input rejection and local-bind/TLS validation. Those tests prove the relay transport using a fixture upstream; they do not establish access to a live paid provider or a remotely deployed TLS proxy. No remote server has been deployed. Run live provider acceptance with your own configured credential, then record the model, date, latency and failure behavior.

For a persistent self-host deployment, use your OS's supported service manager and configure restart-on-failure, secret injection and a dedicated user; no platform-specific privileged service is installed by this repository. Stop with Ctrl-C. No history/database cleanup is needed because the relay persists neither.

References: [Python HTTP server limitations](https://docs.python.org/3/library/http.server.html), [Python HTTP client](https://docs.python.org/3/library/http.client.html).
