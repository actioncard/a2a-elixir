# Elixir A2A — Project Specification

## Overview

An Elixir library that provides a behaviour-based agent framework with built-in Google A2A (Agent-to-Agent) protocol support. Agents are defined once through a common contract and can communicate locally via OTP or externally via the A2A protocol — same interface, transport-transparent.

## Problem Statement

The A2A protocol solves cross-boundary agent interoperability (HTTP, JSON-RPC, SSE). Raw GenServer solves process lifecycle. Neither provides a proper **agent abstraction** — standardized message format, task lifecycle, capability declaration, streaming, multi-turn conversation, or discovery. Every agent built on raw GenServer reinvents these differently.

This library fills that gap: a unified agent contract where A2A protocol export is a free byproduct, not the architecture.

## Architecture

```
┌──────────────────────────────────────────────────┐
│              A2A.Agent Behaviour                 │
│  skills/0 · handle_message/2 · handle_cancel/1   │
└───────┬──────────────────────────────┬───────────┘
        │                              │
  ┌─────▼──────┐               ┌───────▼────────┐
  │  Internal  │               │   External     │
  │  GenServer │               │   A2A.Plug     │
  │  Registry  │               │   JSON-RPC 2.0 │
  │  Streams   │               │   SSE/HTTP     │
  └────────────┘               │   Agent Cards  │
                               └────────────────┘
```

Agents are internal OTP processes by default. Selected agents are exposed externally via A2A protocol through configuration. The router provides location-transparent dispatch — callers don't know or care whether a target agent is local or remote.

```
┌─────────────────────────────────┐
│   Your System (OTP)             │
│                                 │
│  ┌───────────┐   ┌───────────┐  │
│  │  Agent A  │   │  Agent B  │  │    External
│  │ (internal)│   │ (internal)│  │    A2A Agent
│  └─────┬─────┘   └─────┬─────┘  │       ▲
│        └──────┬────────┘        │       │
│          ┌────▼─────┐           │       │
│          │  Gateway │──── A2A.Plug ─────┘
│          │  Agent   │           │
│          └──────────┘           │
└─────────────────────────────────┘
```

---

## A2A Protocol Background

The Agent-to-Agent (A2A) protocol is an open standard by Google (now under the Linux Foundation, Apache 2.0) that enables AI agents to communicate as peers regardless of framework, vendor, or runtime. Current version: v0.3. Official SDKs exist for Python, JS/TS, Go, and .NET. No Elixir SDK exists.

### Key Protocol Concepts

- **Agent Card**: JSON metadata at `/.well-known/agent-card.json` describing identity, capabilities, skills, auth, and endpoint URL.
- **Transport**: HTTP(S) with JSON-RPC 2.0 payloads. SSE for streaming. gRPC as alternative binding (v0.3+).
- **Task**: Server-side unit of work with lifecycle: `submitted → working → completed | failed | canceled | input_required | rejected | auth_required`.
- **Message**: A single turn of communication (role: `user` | `agent`), containing typed **Parts** (text, file, structured data).
- **Artifact**: The output/result of a completed task.
- **Context** (`contextId`): Groups related tasks into a session for multi-turn conversations.
- **Opaque execution**: Agents collaborate without exposing internal state, memory, or tools.

### Core RPC Methods

| Method                                     | Purpose                               |
| ------------------------------------------ | ------------------------------------- |
| `message/send`                             | Send a message, synchronous response  |
| `message/stream`                           | Send a message, receive SSE stream    |
| `tasks/get`                                | Poll task status                      |
| `tasks/cancel`                             | Cancel a running task                 |
| `tasks/resubscribe`                        | Re-subscribe to task SSE stream       |
| `tasks/pushNotificationConfig/set`         | Configure push notification webhook   |
| `tasks/pushNotificationConfig/get`         | Get push notification config          |
| `tasks/pushNotificationConfig/list`        | List push notification configs        |
| `tasks/pushNotificationConfig/delete`      | Delete push notification config       |
| `agent/getAuthenticatedExtendedCard`       | Get authenticated agent card          |

### Relationship to MCP

A2A and MCP (Model Context Protocol) are complementary. MCP standardizes agent-to-tool communication. A2A standardizes agent-to-agent communication. Use MCP for tools/data, A2A for inter-agent collaboration.

---

## Agent Behaviour

### Types

```elixir
@type skill :: %{
  id: String.t(),
  name: String.t(),
  description: String.t(),
  tags: [String.t()]
}

@type part ::
  %{kind: :text, text: String.t()}
  | %{kind: :file, file: map()}
  | %{kind: :data, data: map()}

@type message :: %{
  role: :user | :agent,
  message_id: String.t(),
  parts: [part()]
}

@type context :: %{
  task_id: String.t(),
  context_id: String.t() | nil,
  history: [message()]
}

@type reply ::
  {:reply, [part()]}
  | {:stream, Enumerable.t(part())}
  | {:input_required, [part()]}
  | {:delegate, agent :: module(), message()}
  | {:error, term()}
```

### Required Callbacks

#### `agent_card/0`

Returns agent identity and capabilities. This data is used for both internal registry and external A2A agent card generation.

```elixir
@callback agent_card() :: %{
  name: String.t(),
  description: String.t(),
  version: String.t(),
  skills: [skill()],
  opts: keyword()  # input/output modes, auth config, streaming support
}
```

#### `handle_message/2`

Core agent logic. Receives a message and context, returns a reply. This is transport-agnostic — the same implementation serves both internal OTP calls and external A2A requests.

```elixir
@callback handle_message(message(), context()) :: reply()
```

Reply types:

- `{:reply, parts}` — synchronous completion with result parts
- `{:stream, enumerable}` — streaming response (maps to SSE externally, process messages internally)
- `{:input_required, parts}` — multi-turn; agent needs more information from the caller
- `{:delegate, agent, message}` — forward to another agent
- `{:error, term}` — task failure

### Optional Callbacks

```elixir
# Called when a task is cancelled by the client
@callback handle_cancel(context()) :: :ok | {:error, String.t()}
```

---

## Wire Protocol (A2A v0.3)

This section documents the A2A wire format — the JSON schemas, JSON-RPC binding,
SSE streaming format, and error codes that inform the `A2A.JSON` codec,
`A2A.Plug` server, and `A2A.Client` implementations.

### JSON-RPC 2.0 Binding

All A2A communication uses HTTP POST with JSON-RPC 2.0 envelopes (except agent
card discovery, which is a plain HTTP GET).

#### Request Envelope

```json
{
  "jsonrpc": "2.0",
  "id": "1",
  "method": "message/send",
  "params": { ... }
}
```

#### Success Response

```json
{
  "jsonrpc": "2.0",
  "id": "1",
  "result": { ... }
}
```

#### Error Response

```json
{
  "jsonrpc": "2.0",
  "id": "1",
  "error": {
    "code": -32001,
    "message": "Task not found",
    "data": null
  }
}
```

#### Error Codes

Standard JSON-RPC 2.0 codes:

| Code     | Name                  | Default Message                    |
| -------- | --------------------- | ---------------------------------- |
| `-32700` | JSONParseError        | Invalid JSON payload               |
| `-32600` | InvalidRequestError   | Request payload validation error   |
| `-32601` | MethodNotFoundError   | Method not found                   |
| `-32602` | InvalidParamsError    | Invalid parameters                 |
| `-32603` | InternalError         | Internal error                     |

A2A-specific codes:

| Code     | Name                                             | Default Message                                    |
| -------- | ------------------------------------------------ | -------------------------------------------------- |
| `-32001` | TaskNotFoundError                                | Task not found                                     |
| `-32002` | TaskNotCancelableError                           | Task cannot be canceled                            |
| `-32003` | PushNotificationNotSupportedError                | Push Notification is not supported                 |
| `-32004` | UnsupportedOperationError                        | This operation is not supported                    |
| `-32005` | ContentTypeNotSupportedError                     | Incompatible content types                         |
| `-32006` | InvalidAgentResponseError                        | Invalid agent response                             |
| `-32007` | AuthenticatedExtendedCardNotConfiguredError      | Authenticated Extended Card is not configured      |

### Request Params

#### `MessageSendParams` — used by `message/send` and `message/stream`

| Field           | Type                       | Required |
| --------------- | -------------------------- | -------- |
| `message`       | Message                    | yes      |
| `configuration` | MessageSendConfiguration   | no       |
| `metadata`      | object                     | no       |

#### `MessageSendConfiguration`

| Field                    | Type                     | Required |
| ------------------------ | ------------------------ | -------- |
| `blocking`               | boolean                  | no       |
| `historyLength`          | integer                  | no       |
| `acceptedOutputModes`    | string[]                 | no       |
| `pushNotificationConfig` | PushNotificationConfig   | no       |

#### `TaskQueryParams` — used by `tasks/get`

| Field           | Type    | Required |
| --------------- | ------- | -------- |
| `id`            | string  | yes      |
| `historyLength` | integer | no       |
| `metadata`      | object  | no       |

#### `TaskIdParams` — used by `tasks/cancel`, `tasks/resubscribe`

| Field      | Type   | Required |
| ---------- | ------ | -------- |
| `id`       | string | yes      |
| `metadata` | object | no       |

### Data Schemas

All JSON field names use **camelCase**. The `kind` field is the discriminator
for Parts, Messages, Tasks, and streaming events.

#### Task (`kind: "task"`)

| JSON Field   | Type         | Required | Elixir Field  |
| ------------ | ------------ | -------- | ------------- |
| `id`         | string       | yes      | `id`          |
| `contextId`  | string       | yes      | `context_id`  |
| `status`     | TaskStatus   | yes      | `status`      |
| `history`    | Message[]    | no       | `history`     |
| `artifacts`  | Artifact[]   | no       | `artifacts`   |
| `metadata`   | object       | no       | `metadata`    |
| `kind`       | `"task"`     | yes      | _(literal)_   |

#### TaskStatus

| JSON Field  | Type       | Required | Elixir Field |
| ----------- | ---------- | -------- | ------------ |
| `state`     | TaskState  | yes      | `state`      |
| `message`   | Message    | no       | `message`    |
| `timestamp` | string     | no       | `timestamp`  |

**TaskState** enum — wire values are hyphenated lowercase:

| Wire Value         | Elixir Atom       |
| ------------------ | ----------------- |
| `"submitted"`      | `:submitted`      |
| `"working"`        | `:working`        |
| `"input-required"` | `:input_required` |
| `"completed"`      | `:completed`      |
| `"canceled"`       | `:canceled`       |
| `"failed"`         | `:failed`         |
| `"rejected"`       | `:rejected`       |
| `"auth-required"`  | `:auth_required`  |
| `"unknown"`        | `:unknown`        |

#### Message (`kind: "message"`)

| JSON Field         | Type     | Required | Elixir Field       |
| ------------------ | -------- | -------- | ------------------ |
| `messageId`        | string   | yes      | `message_id`       |
| `role`             | string   | yes      | `role`             |
| `parts`            | Part[]   | yes      | `parts`            |
| `taskId`           | string   | no       | `task_id`          |
| `contextId`        | string   | no       | `context_id`       |
| `referenceTaskIds` | string[] | no       | _(not yet)_        |
| `extensions`       | string[] | no       | `extensions`       |
| `metadata`         | object   | no       | `metadata`         |
| `kind`             | `"message"` | yes   | _(literal)_        |

**Role** enum: `"user"` → `:user`, `"agent"` → `:agent`

#### Part — discriminated union on `kind`

**TextPart** (`kind: "text"`):

| JSON Field | Type     | Required | Elixir Field |
| ---------- | -------- | -------- | ------------ |
| `text`     | string   | yes      | `text`       |
| `metadata` | object   | no       | `metadata`   |
| `kind`     | `"text"` | yes      | `kind`       |

**FilePart** (`kind: "file"`):

| JSON Field | Type        | Required | Elixir Field |
| ---------- | ----------- | -------- | ------------ |
| `file`     | FileContent | yes      | `file`       |
| `metadata` | object      | no       | `metadata`   |
| `kind`     | `"file"`    | yes      | `kind`       |

**DataPart** (`kind: "data"`):

| JSON Field | Type       | Required | Elixir Field |
| ---------- | ---------- | -------- | ------------ |
| `data`     | any        | yes      | `data`       |
| `metadata` | object     | no       | `metadata`   |
| `kind`     | `"data"`   | yes      | `kind`       |

#### FileContent

Wire format is either `FileWithBytes` or `FileWithUri` (at least one of
`bytes` or `uri` must be present):

| JSON Field | Type   | Required | Elixir Field |
| ---------- | ------ | -------- | ------------ |
| `bytes`    | string | no*      | `bytes`      |
| `uri`      | string | no*      | `uri`        |
| `name`     | string | no       | `name`       |
| `mimeType` | string | no       | `mime_type`  |

`bytes` is base64-encoded on the wire.

#### Artifact

| JSON Field    | Type     | Required | Elixir Field  |
| ------------- | -------- | -------- | ------------- |
| `artifactId`  | string   | yes      | `artifact_id` |
| `name`        | string   | no       | `name`        |
| `description` | string   | no       | `description` |
| `parts`       | Part[]   | yes      | `parts`       |
| `extensions`  | string[] | no       | _(not yet)_   |
| `metadata`    | object   | no       | `metadata`    |

#### AgentCard

Served at `GET /.well-known/agent-card.json`.

| JSON Field                          | Type                | Required |
| ----------------------------------- | ------------------- | -------- |
| `name`                              | string              | yes      |
| `description`                       | string              | yes      |
| `url`                               | string              | yes      |
| `version`                           | string              | yes      |
| `skills`                            | AgentSkill[]        | yes      |
| `capabilities`                      | AgentCapabilities   | yes      |
| `defaultInputModes`                 | string[]            | yes      |
| `defaultOutputModes`                | string[]            | yes      |
| `provider`                          | AgentProvider       | no       |
| `documentationUrl`                  | string              | no       |
| `iconUrl`                           | string              | no       |
| `protocolVersion`                   | string              | no       |
| `securitySchemes`                   | map<string, SecurityScheme> | no |
| `security`                          | SecurityRequirement[] | no     |
| `additionalInterfaces`              | AgentInterface[]    | no       |
| `preferredTransport`                | TransportProtocol   | no       |
| `supportsAuthenticatedExtendedCard` | boolean             | no       |

#### AgentSkill

| JSON Field    | Type     | Required |
| ------------- | -------- | -------- |
| `id`          | string   | yes      |
| `name`        | string   | yes      |
| `description` | string   | yes      |
| `tags`        | string[] | yes      |
| `examples`    | string[] | no       |
| `inputModes`  | string[] | no       |
| `outputModes` | string[] | no       |

#### AgentCapabilities

| JSON Field               | Type              | Required |
| ------------------------ | ----------------- | -------- |
| `streaming`              | boolean           | no       |
| `pushNotifications`      | boolean           | no       |
| `stateTransitionHistory` | boolean           | no       |
| `extensions`             | AgentExtension[]  | no       |

#### AgentProvider

| JSON Field     | Type   | Required |
| -------------- | ------ | -------- |
| `organization` | string | yes      |
| `url`          | string | yes      |

#### AgentInterface

| JSON Field  | Type              | Required |
| ----------- | ----------------- | -------- |
| `transport` | TransportProtocol | yes      |
| `url`       | string            | yes      |

**TransportProtocol** enum: `"JSONRPC"`, `"GRPC"`, `"HTTP+JSON"`

#### AgentCard — Elixir Representations

The agent card has **two Elixir representations** that serve different roles:

**`A2A.Agent.card()` (server-side)** — a plain map returned by `agent_card/0`:

```elixir
%{name: "greeter", description: "Greets users", version: "1.0.0",
  skills: [...], opts: []}
```

This is an **identity declaration** — it describes what the agent *is*, not where
it lives. Deployment details (URL, capabilities, provider) are unknown to the
agent module and are supplied by the HTTP layer (`A2A.Plug`) at encoding time via
`A2A.JSON.encode_agent_card/2`.

**`%A2A.AgentCard{}` (client-side)** — a struct decoded from the wire format:

```elixir
%A2A.AgentCard{
  name: "greeter", description: "Greets users",
  url: "https://agent.example.com", version: "1.0.0",
  skills: [...], capabilities: %{streaming: true}, ...
}
```

This is a **complete wire-format card** — it includes all fields a client needs
to communicate with the agent.

**Why not unify?** Server-side agents can't produce a complete AgentCard because
they don't know their own URL or deployment-specific capabilities — those are
determined by the HTTP layer. The current split (agent defines identity, Plug
adds deployment details) keeps concerns separated. A future refactor could have
`A2A.Plug` construct `%AgentCard{}` internally, but changing `agent_card/0`'s
return type would break the `A2A.Agent` behaviour contract.

### Streaming (SSE)

Triggered by `message/stream` or `tasks/resubscribe`. The server responds with
`Content-Type: text/event-stream`.

Each SSE event uses only the `data:` field (no `event:` or `id:` fields):

```
data: {"jsonrpc":"2.0","id":"1","result":{...}}\n\n
```

Each `data:` payload is a complete JSON-RPC 2.0 success response. The `result`
object is discriminated by `kind`:

- `"task"` — full Task snapshot
- `"message"` — agent Message (non-task response)
- `"status-update"` — TaskStatusUpdateEvent
- `"artifact-update"` — TaskArtifactUpdateEvent

#### TaskStatusUpdateEvent (`kind: "status-update"`)

| JSON Field  | Type       | Required |
| ----------- | ---------- | -------- |
| `taskId`    | string     | yes      |
| `contextId` | string     | yes      |
| `status`    | TaskStatus | yes      |
| `final`     | boolean    | yes      |
| `metadata`  | object     | no       |
| `kind`      | `"status-update"` | yes |

When `final` is `true`, the stream closes after this event.

#### TaskArtifactUpdateEvent (`kind: "artifact-update"`)

| JSON Field  | Type     | Required |
| ----------- | -------- | -------- |
| `taskId`    | string   | yes      |
| `contextId` | string   | yes      |
| `artifact`  | Artifact | yes      |
| `append`    | boolean  | no       |
| `lastChunk` | boolean  | no       |
| `metadata`  | object   | no       |
| `kind`      | `"artifact-update"` | yes |

#### Stream Lifecycle

1. Client sends `message/stream` JSON-RPC request via HTTP POST
2. Server responds with `Content-Type: text/event-stream`
3. Server emits `Task`/`Message` events as work progresses
4. `TaskStatusUpdateEvent` events on state transitions
5. `TaskArtifactUpdateEvent` events as artifacts are produced
6. Final `TaskStatusUpdateEvent` with `final: true` closes the stream
7. Client can reconnect with `tasks/resubscribe` if connection drops

### Discovery

- **Public card**: `GET /.well-known/agent-card.json` — unauthenticated
- **Extended card**: `agent/getAuthenticatedExtendedCard` JSON-RPC method —
  requires authentication, returns additional skills/capabilities

### Codec Mapping Summary

Complete field mapping between Elixir structs and JSON wire format:

| Elixir Struct     | Elixir Field         | JSON Field           | Transform          |
| ----------------- | -------------------- | -------------------- | ------------------ |
| `A2A.Task`        | `id`                 | `id`                 | —                  |
| `A2A.Task`        | `context_id`         | `contextId`          | snake → camel      |
| `A2A.Task`        | `status`             | `status`             | nested encode      |
| `A2A.Task`        | `history`            | `history`            | list of Message    |
| `A2A.Task`        | `artifacts`          | `artifacts`          | list of Artifact   |
| `A2A.Task`        | `metadata`           | `metadata`           | passthrough        |
| `A2A.Task`        | _(none)_             | `kind`               | literal `"task"`   |
| `A2A.Task.Status` | `state`              | `state`              | atom → hyphenated  |
| `A2A.Task.Status` | `message`            | `message`            | nested encode      |
| `A2A.Task.Status` | `timestamp`          | `timestamp`          | DateTime → ISO8601 |
| `A2A.Message`     | `message_id`         | `messageId`          | snake → camel      |
| `A2A.Message`     | `role`               | `role`               | atom → string      |
| `A2A.Message`     | `parts`              | `parts`              | list of Part       |
| `A2A.Message`     | `task_id`            | `taskId`             | snake → camel      |
| `A2A.Message`     | `context_id`         | `contextId`          | snake → camel      |
| `A2A.Message`     | `metadata`           | `metadata`           | passthrough        |
| `A2A.Message`     | `extensions`         | `extensions`         | passthrough        |
| `A2A.Message`     | _(none)_             | `kind`               | literal `"message"`|
| `A2A.Artifact`    | `artifact_id`        | `artifactId`         | snake → camel      |
| `A2A.Artifact`    | `name`               | `name`               | —                  |
| `A2A.Artifact`    | `description`        | `description`        | —                  |
| `A2A.Artifact`    | `parts`              | `parts`              | list of Part       |
| `A2A.Artifact`    | `metadata`           | `metadata`           | passthrough        |
| `A2A.Part.Text`   | `text`               | `text`               | —                  |
| `A2A.Part.Text`   | `metadata`           | `metadata`           | passthrough        |
| `A2A.Part.Text`   | `kind`               | `kind`               | `:text` → `"text"` |
| `A2A.Part.File`   | `file`               | `file`               | nested encode      |
| `A2A.Part.File`   | `metadata`           | `metadata`           | passthrough        |
| `A2A.Part.File`   | `kind`               | `kind`               | `:file` → `"file"` |
| `A2A.Part.Data`   | `data`               | `data`               | passthrough        |
| `A2A.Part.Data`   | `metadata`           | `metadata`           | passthrough        |
| `A2A.Part.Data`   | `kind`               | `kind`               | `:data` → `"data"` |
| `A2A.FileContent` | `name`               | `name`               | —                  |
| `A2A.FileContent` | `mime_type`          | `mimeType`           | snake → camel      |
| `A2A.FileContent` | `bytes`              | `bytes`              | binary → base64    |
| `A2A.FileContent` | `uri`                | `uri`                | —                  |
| `A2A.AgentCard`   | `name`               | `name`               | —                  |
| `A2A.AgentCard`   | `description`        | `description`        | —                  |
| `A2A.AgentCard`   | `url`                | `url`                | —                  |
| `A2A.AgentCard`   | `version`            | `version`            | —                  |
| `A2A.AgentCard`   | `skills`             | `skills`             | list of skill maps |
| `A2A.AgentCard`   | `capabilities`       | `capabilities`       | atom keys ↔ camel  |
| `A2A.AgentCard`   | `default_input_modes`| `defaultInputModes`  | snake → camel      |
| `A2A.AgentCard`   | `default_output_modes`| `defaultOutputModes`| snake → camel      |
| `A2A.AgentCard`   | `provider`           | `provider`           | atom keys ↔ string |
| `A2A.AgentCard`   | `documentation_url`  | `documentationUrl`   | snake → camel      |
| `A2A.AgentCard`   | `icon_url`           | `iconUrl`            | snake → camel      |
| `A2A.AgentCard`   | `protocol_version`   | `protocolVersion`    | snake → camel      |

---

## Developer API — Examples

### Minimal Agent

```elixir
defmodule MyApp.InvoiceAgent do
  use A2A.Agent

  @impl true
  def agent_card do
    %{
      name: "invoice-validator",
      description: "Validates invoices against supplier records",
      version: "1.0.0",
      skills: [
        %{
          id: "validate",
          name: "Validate Invoice",
          description: "Checks invoice fields and amounts",
          tags: ["finance"]
        }
      ]
    }
  end

  @impl true
  def handle_message(message, _context) do
    text = A2A.Message.text(message)

    case MyApp.Invoices.validate(text) do
      {:ok, result} ->
        {:reply, [%{kind: :data, data: result}]}

      {:error, reason} ->
        {:reply, [%{kind: :text, text: "Validation failed: #{reason}"}]}
    end
  end
end
```

### Streaming Agent

```elixir
defmodule MyApp.ResearchAgent do
  use A2A.Agent,
    name: "research-agent",
    description: "Deep research on a topic",
    skills: [
      %{id: "research", name: "Research", description: "Multi-source research synthesis", tags: ["research"]}
    ],
    streaming: true

  @impl true
  def handle_message(message, _context) do
    stream =
      Stream.resource(
        fn -> MyApp.Research.start(A2A.Message.text(message)) end,
        fn
          :done -> {:halt, :done}
          state ->
            case MyApp.Research.next_chunk(state) do
              {:chunk, text, new_state} ->
                {[%{kind: :text, text: text}], new_state}
              :complete ->
                {:halt, :done}
            end
        end,
        fn _state -> :ok end
      )

    {:stream, stream}
  end
end
```

### Multi-turn Agent

```elixir
defmodule MyApp.OrderAgent do
  use A2A.Agent,
    name: "order-agent",
    description: "Places food orders",
    skills: [
      %{id: "order", name: "Place Order", description: "Order food from restaurants", tags: ["ordering"]}
    ]

  @impl true
  def handle_message(message, context) do
    text = A2A.Message.text(message)

    case parse_order(text, context.history) do
      {:complete, order} ->
        {:ok, confirmation} = MyApp.Orders.place(order)
        {:reply, [%{kind: :text, text: "Order placed. #{confirmation}"}]}

      {:needs, :address} ->
        {:input_required, [%{kind: :text, text: "What's the delivery address?"}]}

      {:needs, :size} ->
        {:input_required, [%{kind: :text, text: "What size? Small, medium, or large?"}]}
    end
  end
end
```

### Orchestrator Agent (Composing Other Agents)

```elixir
defmodule MyApp.QuoteOrchestrator do
  use A2A.Agent,
    name: "quote-orchestrator",
    description: "Coordinates quote generation"

  @impl true
  def handle_message(message, context) do
    # Local agent — direct OTP call
    with {:reply, specs} <- A2A.call(MyApp.SpecAgent, message, context),
         {:reply, price} <- A2A.call(MyApp.PricingAgent, specs, context),
         # Remote agent — A2A HTTP, same interface
         {:reply, compliance} <- A2A.call(context.agents[:compliance], specs, context) do
      {:reply, [Part.data(%{price: price, compliance: compliance})]}
    end
  end
end
```

---

## Library Components

### Agent Runtime

- `use A2A.Agent` generates a supervised GenServer
- Manages task state machine: `submitted → working → completed | failed | canceled | input_required | rejected | auth_required`
- Context ID tracking and message history accumulation
- Task ID generation

### Router (`A2A.Router` / `A2A.call/3`)

Location-transparent dispatch:

- **Local agent** (module in registry) → direct GenServer call, no serialization
- **Remote agent** (URL or agent card) → A2A HTTP client, full protocol
- **Discovered agent** (from registry search) → resolved at call time

```elixir
# All use the same interface
A2A.call(MyApp.PricingAgent, message, context)          # local
A2A.call("https://supplier.example.com/a2a", msg, ctx)  # remote URL
A2A.call({:a2a, agent_card}, message, context)           # discovered card

# Streaming variant
A2A.stream(MyApp.ResearchAgent, message, context)
|> Stream.each(&process_chunk/1)
|> Stream.run()
```

### Registry (`A2A.Registry`)

Internal agent discovery. Agents are registered automatically on supervision start.

```elixir
A2A.Registry.find_by_skill("finance")
# => [MyApp.PricingAgent, MyApp.RiskAgent]

A2A.Registry.get(MyApp.PricingAgent)
# => %A2A.AgentCard{name: "pricing", skills: [...]}

A2A.Registry.all()
# => [%A2A.AgentCard{}, ...]
```

The same registry data serializes to JSON agent cards for external A2A discovery.

### A2A Server (`A2A.Plug`)

Phoenix/Plug adapter that handles all external A2A protocol concerns:

- `GET /.well-known/agent-card.json` → serialized agent card
- `POST /` → JSON-RPC 2.0 dispatcher
  - `message/send` → calls `handle_message/2`, wraps response in Task + Artifact
  - `message/stream` → calls `handle_message/2`, expects `{:stream, _}`, sends SSE
  - `tasks/get` → reads from task store
  - `tasks/cancel` → calls `handle_cancel/1`

```elixir
# Phoenix router — expose selected agents
forward "/a2a/quotes", A2A.Plug, agent: MyApp.QuoteOrchestrator
forward "/a2a/pricing", A2A.Plug, agent: MyApp.PricingAgent

# Or standalone, no Phoenix
{A2A.Server, agent: MyApp.InvoiceAgent, port: 4001}
```

### A2A Client (`A2A.Client`)

HTTP client for consuming external A2A agents. Requires `req` (optional dep).
All functions accept `%A2A.Client{}`, `%A2A.AgentCard{}`, or a URL string.

```elixir
# Discover an agent
{:ok, card} = A2A.Client.discover("https://pizza-agent.example.com")

# Create a reusable client (optional — carries Req config)
client = A2A.Client.new(card, headers: [{"authorization", "Bearer tok"}])

# Synchronous
{:ok, task} = A2A.Client.send_message(client, "Large margherita to Sveavägen 12")

# Streaming — yields decoded event structs
{:ok, stream} = A2A.Client.stream_message(client, "Research quantum computing")
Enum.each(stream, fn
  %A2A.Event.StatusUpdate{final: true} -> :done
  %A2A.Event.ArtifactUpdate{artifact: art} -> IO.inspect(art)
  event -> IO.inspect(event)
end)

# Multi-turn
{:ok, task} = A2A.Client.send_message(client, "Order a pizza")
{:ok, task} = A2A.Client.send_message(client, "Large, pepperoni",
  task_id: task.id, context_id: task.context_id)

# Task management
{:ok, task} = A2A.Client.get_task(client, task.id)
{:ok, task} = A2A.Client.cancel_task(client, task.id)
```

### Task Store

Pluggable storage backend for task state persistence:

```elixir
# config/config.exs
config :a2a,
  task_store: A2A.TaskStore.ETS            # default, single-node
  # task_store: A2A.TaskStore.PG           # distributed via :pg
  # task_store: {A2A.TaskStore.Redis, url: "redis://..."}
```

Behaviour: `put/2`, `get/1`, `update/2`, `delete/1`.

### Supervision

```elixir
# application.ex
children = [
  {A2A.AgentSupervisor, agents: [
    MyApp.PricingAgent,
    MyApp.RiskAgent,
    MyApp.SpecAgent,
    MyApp.QuoteOrchestrator
  ]}
]
```

Agents are registered in the internal registry on start. Supervised with restart strategies.

---

## Design Decisions

| Decision                                  | Rationale                                                                  |
| ----------------------------------------- | -------------------------------------------------------------------------- |
| Behaviour, not DSL                        | Explicit, testable, no macro magic beyond `use` boilerplate                |
| Internal-first, A2A at edges              | Agents are local OTP by default, exported by configuration                 |
| Transport-transparent routing             | Orchestrators don't know if a dependency is local or remote                |
| Streaming via Elixir `Stream`/`Enumerable`| Idiomatic, composable, maps to SSE naturally                               |
| Pluggable task store                      | ETS for dev/single-node, distributed stores for prod                       |
| Phoenix optional                          | `A2A.Plug` works with bare Plug or Phoenix; `A2A.Server` for standalone    |
| Agent card from code                      | Single source of truth for internal registry and external discovery         |
| `{:delegate, agent, message}` reply type  | First-class agent-to-agent forwarding without manual routing               |
| Two AgentCard representations             | Server agents declare identity (plain map); clients receive full wire card (`%AgentCard{}` struct). Agents don't know their URL — Plug adds deployment details at encoding time. |

---

## Implementation Roadmap

| Phase | Status  | Description                                                        |
| ----- | ------- | ------------------------------------------------------------------ |
| 1     | Done    | Core types + agent runtime (Part, Message, Task, Artifact, Agent behaviour, GenServer, TaskStore) |
| 2     | Done    | Wire protocol spec — document JSON schemas, JSON-RPC, SSE, error codes |
| 3     | Done    | JSON codec (`A2A.JSON`) — Elixir structs ↔ camelCase JSON         |
| 4     | Done    | JSON-RPC layer — request/response parsing, method dispatch, error types |
| 5     | Done    | HTTP server (`A2A.Plug`) — agent card endpoint, JSON-RPC POST, SSE |
| 6     | Done    | HTTP client (`A2A.Client`) — discover, send_message, stream via Req; `A2A.AgentCard` struct |
| 7     | Done    | Registry + Supervisor — agent discovery, supervised startup        |
| 8     | —       | `{:delegate, agent, msg}` — agent-to-agent forwarding             |

### Out of Scope (Initial Release)

- LLM integration (use `instructor`, `langchain`, etc.)
- Tool/function calling (use MCP via `hermes-mcp`)
- Agent reasoning, planning, or memory logic
- UI rendering (A2UI)
- gRPC transport binding
- Push notifications / webhooks
- Auth provider implementations (library provides hooks, not implementations)

---

## Future Work: Agent Discovery

The A2A spec defines three discovery strategies. We currently implement one fully
and one partially:

| Strategy              | Spec Status                    | Our Status                        |
| --------------------- | ------------------------------ | --------------------------------- |
| Well-Known URI        | Specified (RFC 8615)           | Done — `A2A.Plug` serves `GET /.well-known/agent-card.json` |
| Curated Registries    | Acknowledged, no standard API  | Partial — `A2A.Registry` is local-only ETS |
| Direct Configuration  | Mentioned                      | N/A — users hardcode URLs         |

### Current Gaps

**`A2A.Registry` is local-only.** It stores server-side `A2A.Agent.card()` maps
(plain maps without URLs) in ETS. Useful for internal routing ("which of my
agents handles finance?") but not for network-visible discovery. A remote client
can't query it.

**`A2A.Plug` serves a single agent's card.** Each Plug mount exposes one agent.
There's no way to serve a directory of all agents from one endpoint.

**No client-side discovery cache.** `A2A.Client.discover/2` fetches a remote
card but doesn't store it. Repeated discovery hits the network every time.

### Ideas

**Multi-agent Plug / directory endpoint.** Wire `A2A.Registry` into `A2A.Plug`
so a single HTTP endpoint can serve cards for all registered agents. Options:

- Serve a JSON array at `/.well-known/agent-card.json` (non-standard but
  practical — the spec doesn't prohibit it)
- Serve per-agent cards at `/.well-known/agents/{name}/agent-card.json`
- Add a query endpoint (e.g., `GET /agents?skill=finance`) — this would be a
  step toward the curated registry concept, but the spec doesn't prescribe an
  API for this yet

This is the most impactful next step — it connects the local registry to the
spec's Open Discovery mechanism.

**Client-side agent cache.** An `A2A.Client.Registry` that caches discovered
`%AgentCard{}` structs and supports `find_by_skill/2` across remote agents.
Would enable patterns like: discover 10 agents at startup, then route to the
best one based on skill tags at call time.

**Registry change notifications.** The current registry is static after init.
A `Phoenix.PubSub` or `:pg`-based notification system would let Plug endpoints
update when agents come and go, and let distributed registries sync across nodes.

**Standard registry API.** The A2A community is exploring standardizing registry
interactions. If a standard emerges, implement it as a Plug endpoint so our
agents can be registered in external catalogs.

---

## Future Work: Authentication & Security

The A2A spec defines a comprehensive security model around the AgentCard. We
currently implement none of it — auth is listed as out of scope for initial
release, but this section captures the spec's requirements and ideas for
incremental adoption.

### What the Spec Defines

**SecuritySchemes on AgentCard.** The public agent card can declare
authentication requirements via two fields:

- `securitySchemes` — a map of named scheme definitions, each containing exactly
  one of: `apiKeySecurityScheme`, `httpAuthSecurityScheme`,
  `oauth2SecurityScheme`, `openIdConnectSecurityScheme`, `mtlsSecurityScheme`
- `security` — an array of `SecurityRequirement` objects specifying which
  schemes apply globally

Scheme types align with the OpenAPI Specification:

| Scheme Type          | Use Case                                    |
| -------------------- | ------------------------------------------- |
| API Key              | Simple token in header/query                |
| HTTP Auth            | Bearer tokens, Basic auth                   |
| OAuth 2.0            | Authorization Code, Client Credentials, Device Code flows |
| OpenID Connect       | OIDC discovery-based auth                   |
| Mutual TLS           | Certificate-based bidirectional auth        |

Clients are expected to: examine the public card's `securitySchemes`, obtain
credentials out-of-band, and include them in every request per the scheme type.

**Authenticated Extended Card.** The spec defines a two-tier card model:

1. **Public card** — served unauthenticated at `/.well-known/agent-card.json`.
   May advertise `supportsAuthenticatedExtendedCard: true`.
2. **Extended card** — fetched via `GET {AgentCard.url}/../agent/authenticatedExtendedCard`
   (or via JSON-RPC `agent/getAuthenticatedExtendedCard`). Requires
   authentication using schemes declared in the public card. Returns additional
   skills, capabilities, or configuration not visible publicly.

This enables selective disclosure — different clients see different capabilities
based on their identity and permissions.

**Task-level authorization.** Servers must enforce access controls so clients
only access their own tasks. The spec states: "Servers MUST NOT reveal the
existence of resources the client is not authorized to access."

**Push notification security.** Webhook endpoints for push notifications must
validate origin and authenticate credential transmission.

### Current State

- `A2A.AgentCard` struct has no `security_schemes` or `security` fields
- `A2A.JSON.encode_agent_card/2` doesn't encode security fields
- `agent/getAuthenticatedExtendedCard` returns `unsupported_operation` error
- `A2A.Plug` has no auth middleware — all requests are unauthenticated
- No task-level access control — any caller can access any task by ID

### Ideas

**AgentCard security fields.** Add `security_schemes` and `security` to
`%A2A.AgentCard{}` and to `A2A.JSON.encode_agent_card/2`. This is pure data
modeling — no runtime behavior, just the ability to declare auth requirements
in the card.

**Auth plug middleware.** A composable `A2A.Plug.Auth` that:

- Reads `securitySchemes` from the agent card
- Validates credentials on incoming requests (Bearer token check, API key
  lookup, etc.)
- Returns `401` / `403` for invalid/missing credentials
- Passes verified identity to the agent via `context.metadata`

This should be a separate Plug that users compose before `A2A.Plug`, not built
into `A2A.Plug` itself. The library provides the middleware; users supply the
credential verification logic (e.g., "check this JWT against my JWKS endpoint").

**Authenticated extended card.** Implement `agent/getAuthenticatedExtendedCard`:

- Agent behaviour gets an optional `extended_card/1` callback that receives the
  authenticated identity and returns an extended card
- `A2A.Plug` serves it at the spec-defined endpoint, gated by auth middleware
- Enables per-client capability disclosure

**Client-side auth.** `A2A.Client` already accepts Req options (headers, etc.)
so Bearer/API key auth works today via:

```elixir
A2A.Client.new(card, headers: [{"authorization", "Bearer tok"}])
```

More structured support could include: reading `securitySchemes` from a
discovered card and prompting for credentials, or OAuth 2.0 Client Credentials
flow built into the client.

**Task access control.** A callback or plug that maps authenticated identity to
allowed task IDs / context IDs. The runtime would check this before returning
task data from `tasks/get` or `tasks/cancel`.

### Recommended Order

1. AgentCard security fields (data modeling, no runtime changes)
2. Auth plug middleware (Bearer/API key — simplest schemes first)
3. Authenticated extended card endpoint
4. Client-side OAuth 2.0 flows
5. Task-level access control

---

## Dependencies (Expected)

- `plug` — HTTP adapter
- `jason` — JSON encoding/decoding
- `bandit` or `cowboy` — HTTP server (for standalone mode)
- `telemetry` — instrumentation

Optional:
- `phoenix` — for Phoenix router integration
- `redix` — for Redis task store
