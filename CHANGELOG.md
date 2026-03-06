# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
