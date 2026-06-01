# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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

### Changed

- `TaskStatus.timestamp` is now serialized with a `Z` suffix (UTC) per the
  v1.0 schema timestamp regex.
- `A2A.Client` now sends v1.0 PascalCase JSON-RPC method names
  (`SendMessage`, `SendStreamingMessage`, `GetTask`, `CancelTask`). The
  server continues to accept both v1.0 PascalCase and the legacy v0.3
  slash-style names. Pointing the client at a strict v0.3-only server that
  doesn't accept PascalCase is a breaking change.

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
