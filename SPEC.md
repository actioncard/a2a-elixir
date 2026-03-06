# Elixir A2A — Roadmap

Unimplemented work organized by category. Phases 1-7 (core types, agent
runtime, JSON codec, JSON-RPC, HTTP server, HTTP client, registry/supervisor)
and telemetry instrumentation are complete. See the codebase and README for
current functionality.

---

## TCK Compliance

CI runs `bin/tck all` to exercise every
[A2A TCK](https://github.com/a2aproject/a2a-tck) category. Quality and feature
failures are informational (don't block CI); mandatory and capability failures
are fatal.

### Currently Passing

| Category | What it covers | Notes |
|----------|----------------|-------|
| **mandatory / jsonrpc** | JSON-RPC 2.0 compliance, error codes, protocol violations | — |
| **mandatory / protocol** | Agent card, message send, tasks get/list/cancel, state transitions | Extended card tests skip (not implemented) |
| **mandatory / security** | Auth enforcement, auth compliance v0.3.0, agent card security | TLS tests skip (HTTP in test); in-task auth skips |
| **capabilities** | Streaming method validation | Only streaming declared; other capability tests skip |
| **quality** | Concurrency, resilience, edge cases | Informational |
| **features** | Agent card utils, business logic, task ID refs | Informational |

### Skipped (Expected)

| Tests | Reason | Unblocked by |
|-------|--------|--------------|
| Extended agent card | `supportsAuthenticatedExtendedCard` not declared | Authenticated Extended Card (below) |
| In-task authentication | Agent doesn't trigger `auth-required` state | Optional — agent-level decision |
| TLS / certificate validation | TCK server runs plain HTTP on localhost | Deploy-time concern, not library |
| Push notification capabilities | `pushNotifications` not declared | Push Notifications (below) |
| Transport equivalence | Single transport (JSON-RPC only) | gRPC / REST Transport Bindings (below) |
| OAuth2 metadata URL | No OAuth2 scheme configured | Client-Side OAuth 2.0 Flows (below) |

### Roadmap: Feature → TCK Tests Unlocked

| # | Feature | TCK tests enabled |
|---|---------|-------------------|
| 1 | **Push Notifications** | `capabilities/` push notification tests; mandatory push config method tests |
| 2 | **Authenticated Extended Card** | `mandatory/protocol/test_extended_agent_card.py`; `capabilities/` extended card tests |
| 3 | **gRPC Transport Binding** | `transport-equivalence` category (functional equivalence across transports) |
| 4 | **REST Transport Binding** | `transport-equivalence` category |
| 5 | **Task Resubscribe Streaming** | `capabilities/` resubscribe streaming tests |

---

## Protocol

### Push Notifications

The `tasks/pushNotificationConfig/*` methods (set, get, list, delete) currently
return `-32003 PushNotificationNotSupportedError`. Full implementation requires:

- `PushNotificationConfig` struct (url, token, authentication)
- Webhook delivery when task state changes (HTTP POST to configured URL)
- Origin validation and credential transmission security
- `AgentCapabilities.pushNotifications: true` when enabled

Webhook security (informed by a2a_ex):

- HMAC-SHA256 signature generation/verification on webhook payloads
- Replay protection via timestamp and nonce headers
- Private IP range blocking (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
  to prevent SSRF
- Constant-time signature comparison to avoid timing attacks
- HTTPS enforcement on webhook URLs

### Authenticated Extended Card

`agent/getAuthenticatedExtendedCard` currently returns `-32004
UnsupportedOperationError`. Full implementation requires:

- Optional `extended_card/1` callback on the Agent behaviour — receives
  authenticated identity, returns an extended card with additional
  skills/capabilities
- `A2A.Plug` serves it at the spec-defined endpoint, gated by auth middleware
- Public card advertises `supportsAuthenticatedExtendedCard: true`
- Enables per-client capability disclosure (two-tier card model)

### gRPC Transport Binding

A2A v0.3 defines gRPC as an alternative transport. Not started. Would require:

- Protobuf schema definitions mirroring the JSON wire format
- gRPC server module (parallel to `A2A.Plug`)
- `AgentInterface` / `TransportProtocol` support in agent cards

### REST Transport Binding

The A2A spec defines REST as a first-class transport alongside JSON-RPC. Our
library only supports JSON-RPC. Full implementation requires:

- REST endpoint definitions per the spec (`POST /message:send`,
  `POST /message:stream`, `GET /tasks/{id}`, `POST /tasks/{id}:cancel`,
  `GET /tasks`)
- An `A2A.Plug.REST` module (or fold into existing `A2A.Plug` with interface
  routing based on the request path)
- `AgentInterface` / `supportedInterfaces` in the agent card to advertise
  which transports are available (JSON-RPC, REST, gRPC)

### Version & Wire Format Negotiation

Our implementation is hardcoded to A2A v0.3. The spec supports version
selection and wire format options negotiated via HTTP headers. Would require:

- `a2a-version` header parsing and validation on the server — reject
  unsupported versions with an appropriate error
- Version-aware encoding/decoding in `A2A.JSON` (field names and structure
  may differ between spec versions)
- Wire format option (`spec_json` vs `proto_json`) controlling field naming
  conventions (camelCase vs snake_case)
- Client sends version header; server validates compatibility and responds
  with the negotiated version

### Task Resubscribe Streaming

`tasks/resubscribe` is defined in the spec for reconnecting to an active SSE
stream after connection drops. Not yet implemented — would need the runtime to
track active streams per task and resume from the correct point.

---

## Agent Runtime

### `{:delegate, agent, msg}` Reply Type

Phase 8 — not started. First-class agent-to-agent forwarding from within
`handle_message/2`. The runtime would dispatch the message to the target agent
and relay the response back to the original caller transparently.

### Atomic Task Updates

The `A2A.TaskStore` behaviour only has `put/2` and `get/2`. An atomic
`update_task/3` callback that accepts a transformation function would enable
safe concurrent modifications:

- `update_task(store, task_id, fun)` — apply `fun` to the current task
  atomically, returning `{:ok, updated_task}` or `{:error, reason}`
- `A2A.TaskStore.ETS` implementation using optimistic locking (separate lock
  table, retry on conflict) to avoid serializing all updates through a
  single process

---

## Discovery

### Multi-Agent Plug / Directory Endpoint

Currently each `A2A.Plug` mount exposes a single agent's card. A remote client
can't discover all agents from one endpoint. Options:

- JSON array at `/.well-known/agent-card.json` (non-standard but practical —
  the spec doesn't prohibit it)
- Per-agent cards at `/.well-known/agents/{name}/agent-card.json`
- Query endpoint (e.g., `GET /agents?skill=finance`) — a step toward the
  curated registry concept, though the spec doesn't prescribe an API yet

This is the most impactful discovery improvement — it connects the local
registry to the spec's Open Discovery mechanism.

### Client-Side Agent Cache (`A2A.Client.Registry`)

`A2A.Client.discover/2` fetches a remote card but doesn't store it — repeated
discovery hits the network every time. A client-side cache would:

- Store discovered `%AgentCard{}` structs
- Support `find_by_skill/2` across remote agents
- Enable patterns like: discover 10 agents at startup, route to the best one
  based on skill tags at call time

### Registry Change Notifications

The current `A2A.Registry` is static after init. A `Phoenix.PubSub` or
`:pg`-based notification system would:

- Let Plug endpoints update when agents come and go
- Let distributed registries sync across nodes

### Standard Registry API

The A2A community is exploring standardizing registry interactions. If a
standard emerges, implement it as a Plug endpoint so agents can be registered
in external catalogs.

---

## Security

### Client-Side OAuth 2.0 Flows

`A2A.Client` already supports Bearer/API key auth via Req options:

```elixir
A2A.Client.new(card, headers: [{"authorization", "Bearer tok"}])
```

More structured support could include: reading `securitySchemes` from a
discovered card and prompting for credentials, or OAuth 2.0 Client Credentials
flow built into the client.

### Task-Level Access Control

The spec states: "Servers MUST NOT reveal the existence of resources the client
is not authorized to access." Currently any caller can access any task by ID.

A callback or plug that maps authenticated identity to allowed task IDs /
context IDs. The runtime would check this before returning task data from
`tasks/get` or `tasks/cancel`.

### Agent Card Signature Verification

The spec allows agent cards to carry JWS signatures for authenticity
verification. Not yet implemented. Would require:

- `A2A.AgentCard.verify_signatures/2` — validate JWS signatures on a
  decoded agent card against a caller-supplied verifier function
- `AgentCardSignature` struct for signature metadata (algorithm, key ID,
  signature value)
- Verification is opt-in — callers choose whether to verify after decoding
- Depends on a JOSE library (e.g., `jose`) as an optional dependency

### Recommended Security Order

1. Agent card signature verification
2. Authenticated extended card endpoint
3. Client-side OAuth 2.0 flows
4. Task-level access control

---

## Client

### Stream Cancellation

`A2A.Client.send_message_streaming/3` returns a `Stream` but provides no way
to explicitly cancel an in-flight SSE connection. A wrapper struct (similar to
a2a_ex's `A2A.Client.Stream`) would:

- Implement `Enumerable` for lazy consumption
- Expose `cancel/1` to abort the underlying HTTP connection
- Clean up resources on early termination

### SSE Reconnection with Backoff

Dropped SSE connections currently fail permanently. Production-grade streaming
needs:

- Exponential backoff on connection failures (configurable base/max/jitter)
- Resume from `last-event-id` header on reconnect so no events are lost
- Configurable max retry attempts before giving up

### Challenge-Response Auth

When a server returns `401` with auth challenge headers, the client should be
able to auto-retry with appropriate credentials:

- Parse `WWW-Authenticate` headers from 401 responses
- Invoke a caller-supplied auth callback to obtain credentials
- Retry the original request with the new credentials
- Integrates with the existing Req middleware pipeline

---

## Observability

### LiveDashboard Page (Optional)

An `A2A.DashboardPage` module implementing `Phoenix.LiveDashboard.PageBuilder`,
compiled only when `phoenix_live_dashboard` is available (same pattern as Oban).
Would show active agents, task counts, recent tasks with status/duration/errors,
and live state transitions.

---

## Usability

### `A2A.Server` Convenience Module

Wrap Bandit + Plug into a single startable child spec:

```elixir
{A2A.Server, agent: MyApp.InvoiceAgent, port: 4001}
```

### Additional TaskStore Backends

Current: `A2A.TaskStore.ETS` (single-node). Potential additions:

- `A2A.TaskStore.PG` — distributed via `:pg`
- `A2A.TaskStore.Redis` — requires `redix` optional dep

### Forward-Compatible Type Decoding

`A2A.JSON.decode/2` currently discards unrecognized JSON fields. To support
forward compatibility with newer spec versions:

- Preserve unknown fields in a `raw` map on decoded structs (or a dedicated
  `_extra` field)
- Round-trip unknown fields through encode/decode so data isn't silently lost
- Enables interop with agents running newer spec versions that include
  fields this library doesn't yet model

### Extension Metadata Handling

The A2A spec supports extension metadata via HTTP headers and nested metadata
fields. Not yet implemented. Would require:

- Parsing `a2a-extensions` / `x-a2a-extensions` HTTP headers
- `A2A.Extension` module with helpers for getting/putting extension metadata
  on requests and responses
- `missing_required/2` to check whether required extensions declared by an
  agent are present in a request

---

## Out of Scope

These are not planned for this library:

- **LLM integration** — use `instructor`, `langchain`, etc.
- **Tool/function calling** — use MCP via `hermes-mcp`
- **Agent reasoning, planning, or memory** — application-level concerns
- **UI rendering** — A2UI is a separate spec
