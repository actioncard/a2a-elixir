# A2A Elixir — ITK Interoperability Baseline

**Status:** Showcase / instrument PR. **No changes to the A2A Elixir SDK (`lib/`).**
This PR adds a test-harness that drives the *unmodified* SDK against the official
A2A **Interoperability Test Kit (ITK)** and documents — with reproducible
evidence — exactly what works today over JSON-RPC and where the gaps are.

The goal is a measuring stick, not a fix: establish an honest baseline so future
v1.0-migration work is data-driven and regression-gated.

> **Framing (per #13 roadmap "emit v1.0, accept v0.3 on decode").** The deltas
> documented below are **not defects in the SDK** — they are the expected
> **v0.3-client compatibility divergences** observed while the SDK moves to the
> v1.0 wire format. The reference client used here (`a2a-sdk 0.3.24`) is a v0.3
> client; where it rejects current SDK output, that is the v0.3↔v1.0 migration
> surface, captured as compat notes to guide PR 2+ of #13 — not a list of bugs
> to hot-fix in this harness PR. Rebased on current `main` (post-#36 v1.0 wire
> format work).

---

## TL;DR

| Capability | Status | Evidence |
|---|---|---|
| v0.3-shaped Agent Card | ✅ Works | `preferredTransport: JSONRPC`, `protocolVersion: 0.3.0` served at `/jsonrpc/.well-known/agent-card.json` |
| ITK Instruction proto decode (`return_response`, `steps`, `call_agent`) | ✅ Works | `steps_concat` → `[a -> b (jsonrpc)]\ntraversal-completed:jsonrpc` |
| Agent interpreter + Task construction | ✅ Works | 416 unit tests green against pristine SDK |
| `message/send` (non-streaming) round-trip | ✅ Works at wire level | completed Task, `status.message.text = traversal-completed:jsonrpc` |
| ITK end-to-end traversal (Python a2a-sdk 0.3.24 client) | ❌ Fails | enum + streaming-event shape mismatch (below) |

**Bottom line:** the harness, proto codec, and agent logic are sound. Current
`main`'s **JSON wire encoding** does not yet match what the A2A Python **v0.3**
client (`a2a-sdk 0.3.24`) accepts — so a real ITK traversal with a v0.3 client
does not yet pass. Under #13 that is the expected v0.3↔v1.0 migration surface,
documented here as the data-driven entry point for PR 2+; it is **not** changed
in this PR.

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

### ITK traversal — Python a2a-sdk 0.3.24 client (v0.3 compat divergences)

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

## v0.3 client compat notes (seeds PR 2+ of #13 — NOT in this PR)

Under the #13 roadmap ("emit v1.0, accept v0.3 on decode"), the items below are
the **v0.3↔v1.0 divergences** a v0.3 client sees against current `main`. They are
recorded here as the migration surface, in priority order — they are **not**
fixed in this harness PR:

1. **JSON-RPC enum encoding.** Current `main` `A2A.JSON` emits proto-style enums
   (`ROLE_AGENT`, `TASK_STATE_COMPLETED`) on the JSON-RPC transport, which a v0.3
   client (`a2a-sdk 0.3.24`, lowercase `agent`/`completed`) rejects. The v1.0
   direction is the lowercase JSON form on JSON-RPC with proto-style reserved for
   gRPC. Highest-leverage migration item — it blocks every traversal.
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
mix test                       # 416 tests + 2 doctests, 0 failures

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
