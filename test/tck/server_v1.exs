# Boots a Bandit server with the TCK agent for A2A TCK 1.0-dev testing.
# No auth — the 1.0-dev TCK doesn't send auth headers yet.
#
# Usage:
#   A2A_TCK_PORT=9999 mix run test/tck/server_v1.exs

defmodule TCK.Agent do
  use A2A.Agent,
    name: "tck-agent",
    description: "A2A TCK compliance verification agent",
    version: "1.0.0",
    skills: [
      %{
        id: "tck",
        name: "TCK",
        description: "Handles TCK compliance verification messages",
        tags: ["a2a", "compliance"]
      }
    ]

  @impl A2A.Agent
  def handle_message(message, _context) do
    text = A2A.Message.text(message) || ""

    cond do
      String.contains?(text, "need input") ->
        {:input_required, [A2A.Part.Text.new("Please provide additional input")]}

      true ->
        parts = [A2A.Part.Text.new("TCK response: #{text}")]
        {:stream, Stream.concat([parts])}
    end
  end

  @impl A2A.Agent
  def handle_cancel(_context), do: :ok
end

port =
  case System.get_env("A2A_TCK_PORT") do
    nil -> 9999
    val -> String.to_integer(val)
  end

base_url = "http://localhost:#{port}"

{:ok, _} = TCK.Agent.start_link()

{:ok, _} =
  Bandit.start_link(
    plug: {A2A.Plug, [agent: TCK.Agent, base_url: base_url]},
    port: port,
    startup_log: false
  )

IO.puts("TCK v1 server running on #{base_url}")
IO.puts("Agent card: #{base_url}/.well-known/agent-card.json")
IO.puts("Press Ctrl+C to stop")

Process.sleep(:infinity)
