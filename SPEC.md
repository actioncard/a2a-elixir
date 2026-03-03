# Elixir A2A — Roadmap

Unimplemented work organized by category. Phases 1-7 (core types, agent
runtime, JSON codec, JSON-RPC, HTTP server, HTTP client, registry/supervisor)
are complete. See the codebase and README for current functionality.

---

## Protocol

### Push Notifications

The `tasks/pushNotificationConfig/*` methods (set, get, list, delete) currently
return `-32003 PushNotificationNotSupportedError`. Full implementation requires:

- `PushNotificationConfig` struct (url, token, authentication)
- Webhook delivery when task state changes (HTTP POST to configured URL)
- Origin validation and credential transmission security
- `AgentCapabilities.pushNotifications: true` when enabled

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

### AgentCard Security Fields

`%A2A.AgentCard{}` has no `security_schemes` or `security` fields.
`A2A.JSON.encode_agent_card/2` doesn't encode them. Pure data modeling — no
runtime behavior, just the ability to declare auth requirements in the card.

The spec defines these scheme types (aligned with OpenAPI):

| Scheme Type     | Use Case                                               |
| --------------- | ------------------------------------------------------ |
| API Key         | Simple token in header/query                           |
| HTTP Auth       | Bearer tokens, Basic auth                              |
| OAuth 2.0       | Authorization Code, Client Credentials, Device Code    |
| OpenID Connect  | OIDC discovery-based auth                              |
| Mutual TLS      | Certificate-based bidirectional auth                   |

### Auth Plug Middleware (`A2A.Plug.Auth`)

A composable Plug that:

- Reads `securitySchemes` from the agent card
- Validates credentials on incoming requests (Bearer token check, API key
  lookup, etc.)
- Returns `401` / `403` for invalid/missing credentials
- Passes verified identity to the agent via `context.metadata`

Should be a separate Plug that users compose before `A2A.Plug` — the library
provides middleware, users supply credential verification logic.

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

### Recommended Security Order

1. AgentCard security fields (data modeling, no runtime changes)
2. Auth plug middleware (Bearer/API key — simplest schemes first)
3. Authenticated extended card endpoint
4. Client-side OAuth 2.0 flows
5. Task-level access control

---

## Observability

### Telemetry Events

The library declares `{:telemetry, "~> 1.2"}` but emits zero events. Following
the Ecto/Oban pattern (library emits, app wires up), add spans and events:

Spans via `:telemetry.span/3`:

```
[:a2a, :agent, :call]     — wraps full A2A.call/3 lifecycle
[:a2a, :agent, :message]  — wraps handle_message/2 callback
[:a2a, :agent, :cancel]   — wraps handle_cancel/1 callback
```

Each span emits `start/stop/exception` with `%{duration, system_time}` and
metadata `%{agent, task_id, context_id, status}`.

Discrete events:

```
[:a2a, :task, :transition] — on every task state change
  metadata: %{agent, task_id, from, to}
```

Emit sites: `process_message/4` in Agent.Runtime (message span),
`A2A.call/3` and `A2A.stream/3` (call span), `transition/2` in Agent.State
(transition event).

Add an `A2A.Telemetry` module documenting all events as a public API contract.

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

---

## Out of Scope

These are not planned for this library:

- **LLM integration** — use `instructor`, `langchain`, etc.
- **Tool/function calling** — use MCP via `hermes-mcp`
- **Agent reasoning, planning, or memory** — application-level concerns
- **UI rendering** — A2UI is a separate spec
