# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Caching headers on the agent card endpoint per A2A v1.0 §8.6: a quoted
  `sha256` `ETag` computed from the response body, a `Last-Modified` in RFC
  7231 IMF-fixdate form, and `Cache-Control: public, max-age=300`. The ETag
  is computed per request, since `A2A.Plug.put_base_url/2` can change the
  body. Note the `Cache-Control` value changes even for callers that set
  nothing: responses previously carried Plug's default of
  `max-age=0, private, must-revalidate`, which is wrong for a public card.
- `A2A.Plug` `:last_modified` option — the `DateTime` served in the agent
  card's `Last-Modified` header (default: `DateTime.utc_now()` evaluated in
  `init/1`, so build time under Phoenix's compile-time `plug` macro and boot
  time otherwise).
- `A2A.Plug` task-level authorization hook for `tasks/get`, `tasks/cancel`, and
  `tasks/list`
- A2A v1.0 wire format on encode: flat `Part` (no `kind`, with `text` /
  `data` / `raw` / `url` / `mediaType` / `filename`); `Task`, `Message`, and
  `Artifact` no longer carry a `kind` field; AgentCard top-level `url` and
  `protocolVersion` removed (now per-interface under `supportedInterfaces[]`).
  Decoder accepts both v1.0 and the legacy v0.3 nested-`file` form, so v0.3
  clients keep working.
- `Message.reference_task_ids`, `Artifact.extensions`, and
  `AgentCard.signatures` struct fields for v1.0 data carriage.
- A2A v1.0 extension mechanism: `A2A.Extension` behaviour with
  `declaration/1`, `activate/3`, `handle_request/3`, and
  `handle_response/3` callbacks; `A2A.AgentExtension` struct for
  declarations; `A2A-Extensions` header negotiation in `A2A.Plug` and
  `A2A.Client`; merge of declared extensions into the agent card's
  `capabilities.extensions`; `context.extensions` map for agents to read
  per-request activations; `A2A.Extension.Timestamp` as a reference
  implementation.
- A2A v1.0 `A2A-Version` header negotiation: `A2A.Version` helper module;
  `A2A.Plug` `:versions` option (defaults to `["0.3", "1.0"]`) validates
  the request header and returns `VersionNotSupportedError` (-32009) for
  unsupported versions; negotiated version echoed in the response header.
  `A2A.Client` `:version` option (defaults to `"1.0"`) sets the request
  header on every call; `A2A.Client.version/1` reads the server's
  echoed value. Missing/empty headers are interpreted as `"0.3"`
  (spec §3.6.2) and only `Major.Minor` is significant.

### Fixed

- `message/send` now honours `configuration.historyLength`, truncating the
  returned task's history the same way `tasks/get` already did. It was
  previously ignored, so the full history came back regardless.
- `historyLength` is now also accepted under its protobuf spelling
  `history_length` on `tasks/get`, `tasks/cancel` and `tasks/resubscribe`.
  The spec and the REST binding use `historyLength`, but some JSON-RPC
  clients send the proto field name and the reference implementation accepts
  both; previously the limit was silently ignored.
- `message/send` and `message/stream` with an unknown `taskId` now return
  `-32001 TaskNotFoundError` instead of `-32603 InternalError`
- `message/send` and `message/stream` targeting a task in a terminal state now
  return `-32004 UnsupportedOperationError` instead of `-32603 InternalError`

### Changed

- **Breaking:** `message/stream` is now gated on the declared streaming
  capability. A server that does not advertise `capabilities.streaming`
  returns `-32004 UnsupportedOperationError` instead of opening an SSE
  stream, per A2A v1.0 `CORE-CAP-002`. Since capabilities default to `%{}`,
  every server using the defaults is affected. To keep streaming, pass the
  capability to `A2A.Plug`:

  ```elixir
  {A2A.Plug, agent: MyAgent, base_url: url,
   agent_card_opts: [capabilities: %{streaming: true}]}
  ```

  Note that `use A2A.Agent, opts: [...]` does *not* work for this — the
  generated card's `:opts` key is never read (tracked separately).
- `TaskStatus.timestamp` is now serialized with a `Z` suffix (UTC) per the
  v1.0 schema timestamp regex.
- `A2A.Client` now sends v1.0 PascalCase JSON-RPC method names
  (`SendMessage`, `SendStreamingMessage`, `GetTask`, `CancelTask`). The
  server continues to accept both v1.0 PascalCase and the legacy v0.3
  slash-style names. Pointing the client at a strict v0.3-only server that
  doesn't accept PascalCase is a breaking change.
- Minimum Erlang/OTP is now 27. CI tests Elixir 1.17 and 1.18 on OTP 27, 1.19
  on OTP 28, and 1.20 on OTP 29 — the three OTP majors upstream still
  maintains. OTP 25 and 26 are no longer supported or tested; both are past
  end-of-life, and OTP 25 has had no patches, including security fixes, since
  May 2025. The Elixir requirement is unchanged at `~> 1.17`.
- The TCK compliance suite now targets A2A v1.0 only. Upstream replaced its
  v0.3 category suite with the v1.0 `tests/compatibility/` tests, so the v0.3
  compliance server (`test/tck/server.exs`) and the duplicated `bin/tck-v1`
  lane have been removed. Known failures are tracked in
  `test/tck/expected-failures.txt` and the job is red until they are closed;
  it fails only when the failure set differs from that baseline. This affects
  the compliance harness only — the server still accepts v0.3 on the wire.
- `jose` is no longer declared as a direct dependency or pinned to 1.11.10.
  The pin existed only to keep OTP 25 compiling; this library verifies JWTs
  through Joken and never calls JOSE directly, so jose is now an ordinary
  transitive dependency of the optional `joken` dep.

## [0.2.0] - 2026-03-06

### Added

- Telemetry instrumentation for call, message, cancel, and task transitions
- Security scheme data modeling (`A2A.SecurityScheme.*` structs) on `AgentCard`
- Auth middleware (`A2A.Plug.Auth`) — Bearer, Basic, API key, OAuth2, OpenID Connect
- TCK compliance across all categories (mandatory, capabilities, quality, features)
- TCK results posted as PR comments in CI

### Fixed

- Accept v1.0 field names (`bytes`/`uri`) in `FileContent` decoding
- Reject messages with missing `messageId` or empty `parts` per spec
- Reject negative `historyLength` on all methods
- Reject cancel on tasks in terminal states (completed/canceled/failed)

### Changed

- CI runs full TCK suite (`bin/tck all`) instead of mandatory only

## [0.1.1] - 2026-03-03

### Added

- Automated Hex publishing to `actioncard` org on GitHub releases
- Dependabot configuration for Mix deps and GitHub Actions
- Issue and PR templates

### Fixed

- Minor doc cleanups: internal module references, typespec refinement


## [0.1.0] - 2026-03-03

### Added

- A2A protocol types: `Task`, `Message`, `Part`, `Artifact`, `Event`, `FileContent`
- Agent behaviour (`A2A.Agent`) with runtime and state management
- Agent card discovery (`A2A.AgentCard`) with full wire-format support
- JSON-RPC 2.0 transport layer (`A2A.JSONRPC`) with request/response/error types
- Plug-based HTTP server (`A2A.Plug`) with SSE streaming support
- HTTP client (`A2A.Client`) with SSE streaming via Req
- Task store behaviour (`A2A.TaskStore`) with ETS implementation
- Agent registry and supervisor for multi-agent deployments
- Comprehensive JSON encoding/decoding with `A2A.JSON`
- A2A TCK (Technology Compatibility Kit) compliance
