# A2A

[![Hex.pm](https://img.shields.io/hexpm/v/a2a.svg)](https://hex.pm/packages/a2a)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/a2a)
[![CI](https://github.com/actioncard/a2a-elixir/actions/workflows/ci.yml/badge.svg)](https://github.com/actioncard/a2a-elixir/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/a2a.svg)](LICENSE)
[![AI Assisted](https://img.shields.io/badge/AI-Assisted-blue)](CONTRIBUTING.md)

Elixir implementation of the [Agent-to-Agent (A2A) protocol](https://google.github.io/A2A/) — a standard for AI agents to communicate over JSON-RPC 2.0.

A2A gives you behaviour-based agents that run as GenServer processes. Define an agent, serve it over HTTP, or call remote agents — all with idiomatic Elixir patterns.

> **Pre-release**: This library is under active development. The API may change before 1.0.

> [!NOTE]
> This project is developed with _significant_ AI assistance (Claude, Copilot, etc.)

## Features

- **Behaviour-based agents** — `use A2A.Agent` generates a full GenServer with task lifecycle management
- **Multi-turn conversations** — continue tasks with `task_id` for stateful back-and-forth
- **Streaming** — return `{:stream, enumerable}` from agents; SSE over HTTP
- **HTTP serving** — `A2A.Plug` handles agent card discovery, JSON-RPC dispatch, and SSE streaming
- **HTTP client** — `A2A.Client` for discovering and calling remote A2A agents
- **Agent registry** — `A2A.Registry` for skill-based agent discovery
- **Supervision** — `A2A.AgentSupervisor` starts a fleet of agents with one call
- **Pluggable storage** — `A2A.TaskStore` behaviour with built-in ETS implementation
- **Telemetry** — `:telemetry` spans and events for calls, messages, cancels, and state transitions

## Quick Start

```elixir
# Define an agent
defmodule MyAgent do
  use A2A.Agent,
    name: "my-agent",
    description: "Does things"

  @impl A2A.Agent
  def handle_message(message, _context) do
    {:reply, [A2A.Part.Text.new("Got: #{A2A.Message.text(message)}")]}
  end
end

# Start and call it
{:ok, _pid} = MyAgent.start_link()
{:ok, task} = A2A.call(MyAgent, "hello")
```

Agents return `{:reply, parts}`, `{:input_required, parts}`, or `{:stream, enumerable}` from `handle_message/2`. The runtime handles task creation, state transitions, and history.

## Serving over HTTP

`A2A.Plug` exposes your agent as an A2A-compliant HTTP endpoint with agent card discovery and JSON-RPC dispatch.

```elixir
# Standalone with Bandit
{:ok, _pid} = MyAgent.start_link()

Bandit.start_link(
  plug: {A2A.Plug, agent: MyAgent, base_url: "http://localhost:4000"}
)

# Or in a Phoenix router
forward "/a2a", A2A.Plug,
  agent: MyAgent, base_url: "http://localhost:4000/a2a"
```

The agent card is served at `GET /.well-known/agent-card.json` by default.

## Calling Remote Agents

`A2A.Client` discovers and communicates with remote A2A agents over HTTP. Requires the `req` optional dependency.

```elixir
# Discover an agent
{:ok, card} = A2A.Client.discover("https://agent.example.com")

# Send a message
client = A2A.Client.new(card)
{:ok, task} = A2A.Client.send_message(client, "Hello!")

# Stream a response
{:ok, stream} = A2A.Client.stream_message(client, "Count to 5")
Enum.each(stream, &IO.inspect/1)
```

All functions also accept a URL string directly: `A2A.Client.send_message("https://agent.example.com", "Hello!")`.

## Multi-Turn & Streaming

Continue an existing task by passing `task_id`:

```elixir
{:ok, task} = A2A.call(MyAgent, "order pizza")
# task.status.state => :input_required

{:ok, task} = A2A.call(MyAgent, "large", task_id: task.id)
```

For streaming agents, return `{:stream, enumerable}` and consume with `A2A.stream/3`:

```elixir
{:ok, task, stream} = A2A.stream(MyAgent, "research topic")
stream |> Stream.each(&process/1) |> Stream.run()
```

## Supervision & Registry

Start a fleet of agents with a shared registry for skill-based discovery. The current registry is a minimal in-memory implementation covering basic lookup and skill-based routing — production use cases with many agents may warrant a custom registry backed by persistent storage.

```elixir
{:ok, _sup} =
  A2A.AgentSupervisor.start_link(
    agents: [MyApp.PricingAgent, MyApp.RiskAgent, MyApp.SummaryAgent]
  )

# Find agents by skill tag
A2A.Registry.find_by_skill(A2A.Registry, "finance")
#=> [MyApp.PricingAgent, MyApp.RiskAgent]
```

## Installation

Add `a2a` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:a2a, "~> 0.2.0"}
  ]
end
```

### Optional Dependencies

Include only what you need:

```elixir
def deps do
  [
    {:a2a, "~> 0.2.0"},

    # For serving A2A endpoints
    {:plug, "~> 1.16"},
    {:bandit, "~> 1.5"},

    # For calling remote A2A agents
    {:req, "~> 0.5"}
  ]
end
```

## Examples

The [`examples/`](https://github.com/actioncard/a2a-elixir/tree/main/examples) directory contains runnable scripts:

- **[`demo.exs`](https://github.com/actioncard/a2a-elixir/blob/main/examples/demo.exs)** — local agents: simple call, multi-turn, and streaming
- **[`client_server.exs`](https://github.com/actioncard/a2a-elixir/blob/main/examples/client_server.exs)** — full HTTP client/server with Bandit and `A2A.Client`
- **[`supervisor_demo.exs`](https://github.com/actioncard/a2a-elixir/blob/main/examples/supervisor_demo.exs)** — `A2A.AgentSupervisor`, registry, and skill-based routing

Run any example with:

```bash
mix run examples/demo.exs
```

## Development

```bash
# Fetch dependencies
mix deps.get

# Run tests
mix test

# Run the full quality suite (format + credo + dialyzer)
mix quality

# Run checks individually
mix format --check-formatted
mix credo --strict
mix dialyzer
```

Requires Elixir ~> 1.17.

### TCK (Protocol Compliance)

The [A2A TCK](https://github.com/a2aproject/a2a-tck) is the official compliance test suite for the A2A protocol. It runs against a live server and validates protocol conformance.

**Prerequisites:** [uv](https://docs.astral.sh/uv/) (Python package manager)

```bash
# Run mandatory compliance tests (clones TCK on first run)
bin/tck mandatory

# Run all categories
bin/tck all

# Available categories: mandatory, capabilities, quality, features, all
```

To run the server manually (e.g. for debugging):

```bash
# Default port 9999
mix run test/tck/server.exs

# Custom port
A2A_TCK_PORT=8080 mix run test/tck/server.exs
```

The TCK runs on every PR in CI. Reports are uploaded as build artifacts.

## Not Yet Implemented

Key A2A spec features not yet covered:

- **Push notifications** — webhook delivery on task state changes
- **Authenticated extended cards** — per-client capability disclosure
- **REST / gRPC transports** — only JSON-RPC is supported
- **Version negotiation** — hardcoded to A2A v0.3
- **Task resubscribe** — reconnecting to active SSE streams
- **Security middleware** — auth plug, agent card signatures, task-level ACL (security scheme data modeling is complete)

See [SPEC.md](SPEC.md) for full details and roadmap.

## Links

- [A2A Protocol Specification](https://google.github.io/A2A/)
- [Hex Package](https://hex.pm/packages/a2a)
- [Documentation](https://hexdocs.pm/a2a)
- [`a2a_ex`](https://hex.pm/packages/a2a_ex) — alternative Elixir implementation focused on protocol codec and transport (REST + JSON-RPC); complements this library's agent runtime and OTP integration

## License

Apache-2.0 — see [LICENSE](LICENSE).
