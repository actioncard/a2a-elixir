# Run with: mix run examples/extensions.exs
#
# Demonstrates the A2A v1.0 extension mechanism end-to-end:
#   - Server declares A2A.Extension.Timestamp in its agent card
#   - Client advertises support via the A2A-Extensions header
#   - Server activates the extension, runs handle_request/handle_response
#   - Round-tripped Task carries timestamp metadata under the extension URI

# ─── Agent ──────────────────────────────────────────────────────────

defmodule Example.EchoAgent do
  use A2A.Agent,
    name: "echo-with-extensions",
    description: "Echo agent that participates in extension negotiation",
    skills: [
      %{id: "echo", name: "Echo", description: "Echoes input", tags: ["demo"]}
    ]

  @impl A2A.Agent
  def handle_message(message, context) do
    activated = Map.keys(context.extensions)

    text =
      "You said: #{A2A.Message.text(message)}. " <>
        "Activated extensions: #{Enum.join(activated, ", ")}"

    {:reply, [A2A.Part.Text.new(text)]}
  end
end

# ─── Server ─────────────────────────────────────────────────────────

IO.puts("=== A2A Extensions Demo ===\n")

{:ok, _agent_pid} = Example.EchoAgent.start_link()

{:ok, server} =
  Bandit.start_link(
    plug:
      {A2A.Plug,
       agent: Example.EchoAgent,
       base_url: "http://localhost:4011",
       extensions: [A2A.Extension.Timestamp]},
    port: 4011,
    startup_log: false
  )

Process.sleep(100)
IO.puts("Server running on port 4011 with A2A.Extension.Timestamp configured.\n")

# ─── Agent card advertises the extension ───────────────────────────

IO.puts("--- 1. Agent card ---")
{:ok, card} = A2A.Client.discover("http://localhost:4011")

for ext <- card.capabilities[:extensions] || [] do
  required = if ext.required, do: "required", else: "optional"
  IO.puts("  #{ext.uri}  (#{required})")
  IO.puts("    #{ext.description}")
end

IO.puts("")

# ─── Round-trip with the client opting in ──────────────────────────

IO.puts("--- 2. Round-trip with client opting in ---")

client =
  A2A.Client.new("http://localhost:4011",
    extensions: [A2A.Extension.Timestamp]
  )

{:ok, task} = A2A.Client.send_message(client, "hello!")

reply =
  task.history
  |> Enum.filter(&(&1.role == :agent))
  |> List.last()
  |> A2A.Message.text()

IO.puts("  Agent reply: #{reply}")

stamp = task.metadata[A2A.Extension.Timestamp.uri()]
IO.puts("  Task metadata under extension URI:")
IO.puts("    received_at:  #{stamp["received_at"]}")
IO.puts("    completed_at: #{stamp["completed_at"]}")
IO.puts("    elapsed_ms:   #{stamp["completed_at"] - stamp["received_at"]}")
IO.puts("")

# ─── Round-trip with the client *not* opting in ────────────────────

IO.puts("--- 3. Round-trip with client not opting in ---")

bare_client = A2A.Client.new("http://localhost:4011")
{:ok, bare_task} = A2A.Client.send_message(bare_client, "ignore me")

IO.puts("  Agent reply: ")

bare_task.history
|> Enum.filter(&(&1.role == :agent))
|> List.last()
|> A2A.Message.text()
|> IO.puts()

IO.puts("  Extension URI in task.metadata? #{Map.has_key?(bare_task.metadata, A2A.Extension.Timestamp.uri())}")
IO.puts("  (Extension was advertised by server but not requested by client.)")
IO.puts("")

# ─── Cleanup ───────────────────────────────────────────────────────

Supervisor.stop(server)
IO.puts("Done!")
