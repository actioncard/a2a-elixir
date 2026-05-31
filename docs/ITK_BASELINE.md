# A2A Elixir — ITK Interoperability Baseline

**Status:** Showcase / instrument PR. **No changes to the A2A Elixir SDK (`lib/`).**
This PR adds a test-harness that drives the *unmodified* SDK against the official
A2A **Interoperability Test Kit (ITK)** and documents — with reproducible
evidence — exactly what works today over JSON-RPC and where the gaps are.

The goal is a measuring stick, not a fix: establish an honest baseline so future
v1.0-compliance work is gap-driven and regression-gated.

---

## TL;DR

| Capability | Status | Evidence |
|---|---|---|
| v0.3-shaped Agent Card | ✅ Works | `preferredTransport: JSONRPC`, `protocolVersion: 0.3.0` served at `/jsonrpc/.well-known/agent-card.json` |
| ITK Instruction proto decode (`return_response`, `steps`, `call_agent`) | ✅ Works | `steps_concat` → `[a -> b (jsonrpc)]\ntraversal-completed:jsonrpc` |
| Agent interpreter + Task construction | ✅ Works | 404 unit tests green against pristine SDK |
| `message/send` (non-streaming) round-trip | ✅ Works at wire level | completed Task, `status.message.text = traversal-completed:jsonrpc` |
| ITK end-to-end traversal (Python a2a-sdk 0.3.24 client) | ❌ Fails | enum + streaming-event shape mismatch (below) |

**Bottom line:** the harness, proto codec, and agent logic are sound. The SDK's
**JSON wire encoding** does not match what the A2A Python v0.3 client
(`a2a-sdk 0.3.24`) accepts — so a real ITK traversal does not yet pass. That
gap is documented here as the entry point for v1.0 work; it is **not** fixed in
this PR.

---

## What this PR adds (harness only)

```
test/support/itk/instruction.ex   # ITK Instruction protobuf codec (decode/encode)
test/support/itk/agent.ex         # A2A.Test.ITK.Agent — JSON-RPC handler / interpreter
test/itk/server.exs               # standalone Bandit server (v0.3 card + JSON-RPC + SSE)
test/itk/instruction_test.exs     # codec unit tests
test/itk/agent_test.exs           # interpreter unit tests
test/itk/fixtures/*.bin           # encoded Instruction fixtures
```

Plus, in the ITK working copy (not part of the SDK repo): an `elixir_v03` agent
definition + baseline driver (`itk_baseline_elixir.py`) that boots the Elixir
server and runs ITK euler traversals against `python_v03`.

**No `lib/` changes.** Verified: `git diff --stat origin/main -- lib/` is empty.

---

## The v0.3 vs v1.0 axis (what "compliance" means here)

ITK has **no per-agent v0.3/v1.0 switch**. The version axis is *which SDK build*
is registered (`python_v03`/`go_v03` vs `python_v10`/`go_v10`). The Instruction
proto is identical across versions; the differences are in **transport surface
and JSON wire shape**:

- **Agent Card shape:** v0.3 clients want `preferredTransport` +
  `additionalInterfaces`; v1.0 emits `supportedInterfaces`. The Elixir SDK's
  `A2A.JSON.encode_agent_card` emits the v1.0 `supportedInterfaces` shape, which
  the v0.3 Python `ClientFactory` cannot consume — so the harness server
  hand-builds a v0.3 card. (Run the server with `--cardVersion v1` to serve the
  SDK's native v1.0 card and observe the v0.3 client reject it.)

- **Enum wire format (the core gap):** `a2a-sdk 0.3.24` (the reference v0.3
  JSON-RPC client) uses **lowercase JSON enums** — `Role.agent = "agent"`,
  `TaskState.completed = "completed"`. The Elixir SDK's `A2A.JSON` emits
  **proto-style** enums — `"ROLE_AGENT"`, `"TASK_STATE_COMPLETED"` (these belong
  on the gRPC/proto transport, not JSON-RPC). The v0.3 client's pydantic
  validation rejects them.

- **Streaming event shape:** the ITK client's `send_message` uses
  `message/stream` (SSE) as its **primary** path and requires
  `Content-Type: text/event-stream`. The harness server now responds with SSE,
  but the first event (a Task snapshot) is validated against the streaming-event
  union (`TaskStatusUpdateEvent` / `TaskArtifactUpdateEvent`), which requires
  `taskId` and `kind` fields the snapshot does not carry in the expected form.

---

## Baseline results (reproducible)

### Capability probe — raw JSON-RPC (what works)

```
# 1. Agent card
preferredTransport: JSONRPC | protocolVersion: 0.3.0 | url: http://127.0.0.1:PORT/jsonrpc/

# 2. message/send (return_response)
task.status.state: TASK_STATE_COMPLETED         # <- proto-style enum (gap)
reply text: traversal-completed:jsonrpc          # <- interpreter correct
role(raw): ROLE_AGENT                            # <- proto-style enum (gap)

# 3. message/send (steps_concat — multi-step interpret)
reply text: '[a -> b (jsonrpc)]\ntraversal-completed:jsonrpc'
```

The interpreter and proto codec produce the correct traversal tokens; the
**enum casing** is the visible gap even before involving the streaming client.

### ITK traversal — Python a2a-sdk 0.3.24 client (the gaps)

```
==== ITK ELIXIR v0.3 BASELINE RESULTS ====
elixir-single-jsonrpc:     FAIL
elixir-py03-AB-jsonrpc:    FAIL
elixir-py03-AB-streaming:  FAIL
```

Pydantic validation errors from the client (verbatim):

```
status.message.role  -> Input should be 'agent' or 'user' [got 'ROLE_AGENT']
status.state         -> Input should be 'completed'... [got 'TASK_STATE_COMPLETED']
TaskStatusUpdateEvent.taskId  -> Field required
TaskArtifactUpdateEvent.kind  -> Input should be 'artifact-update' [got 'task']
```

---

## Prioritized gap list (seeds future v1.0 work — NOT in this PR)

1. **JSON-RPC enum encoding.** `A2A.JSON` should emit lowercase v0.3 JSON enums
   (`agent`, `completed`, …) on the JSON-RPC transport; reserve proto-style
   enums (`ROLE_AGENT`, `TASK_STATE_COMPLETED`) for gRPC. This is the single
   highest-leverage fix — it blocks every traversal.
2. **Streaming event envelopes.** Emit proper `TaskStatusUpdateEvent` /
   `TaskArtifactUpdateEvent` SSE events (with `taskId`, `kind`) rather than a
   raw Task snapshot, so the v0.3 streaming client can parse the stream.
3. **Agent Card v0.3 emission.** Optionally let `encode_agent_card` emit the
   v0.3 `preferredTransport`/`additionalInterfaces` shape so a hand-built card
   is unnecessary.
4. **gRPC / REST transports.** Required for full ITK multi-transport multi-hop;
   deferred (REST scaffolding parked outside this PR).

---

## Reproduce

```bash
# Unit tests (harness, against pristine SDK)
cd a2a-elixir
mix test                       # 404 tests + 2 doctests, 0 failures

# Standalone server (MUST be MIX_ENV=test — test/support is test-only)
MIX_ENV=test mix run test/itk/server.exs --httpPort 10130
#   GET  /jsonrpc/.well-known/agent-card.json   -> v0.3 card
#   POST /jsonrpc/ (message/send, FilePart=Instruction proto) -> completed Task
#   --cardVersion v1   serves the SDK's native v1.0 card (to show the v0.3 gap)

# Full ITK baseline driver (boots the Elixir agent, runs euler traversals)
cd /path/to/a2a-samples/itk
uv run --no-sources python itk_baseline_elixir.py
```

## Notes

- The standalone server **must** run under `MIX_ENV=test`: the harness modules
  live in `test/support/`, which is only on `elixirc_paths` in the test env.
- Reference client: `a2a-sdk 0.3.24` (Python).
