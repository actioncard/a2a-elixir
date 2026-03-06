# Boots a Bandit server with the TCK agent for A2A TCK compliance testing.
#
# Usage:
#   mix run test/tck/server.exs
#
# Environment:
#   A2A_TCK_PORT  — HTTP port (default: 9999)
#   A2A_TCK_TOKEN — bearer token for auth (default: "tck-test-token")

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

defmodule TCK.Router do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, %{auth: auth_opts, plug: plug_opts}) do
    conn = A2A.Plug.Auth.call(conn, auth_opts)
    if conn.halted, do: conn, else: A2A.Plug.call(conn, plug_opts)
  end
end

port =
  case System.get_env("A2A_TCK_PORT") do
    nil -> 9999
    val -> String.to_integer(val)
  end

token = System.get_env("A2A_TCK_TOKEN") || "tck-test-token"
base_url = "http://localhost:#{port}"

schemes = %{
  "bearer_auth" => %A2A.SecurityScheme.HTTPAuth{scheme: "bearer"}
}

security = [%{"bearer_auth" => []}]

verify = fn
  "bearer_auth", credential, _conn ->
    if credential == token,
      do: {:ok, %{"agent" => "tck"}},
      else: {:error, "invalid token"}
end

auth_opts =
  A2A.Plug.Auth.init(
    schemes: schemes,
    security: security,
    verify: verify
  )

plug_opts =
  A2A.Plug.init(
    agent: TCK.Agent,
    base_url: base_url,
    agent_card_opts: [
      security_schemes: schemes,
      security: security
    ]
  )

{:ok, _} = TCK.Agent.start_link()

{:ok, _} =
  Bandit.start_link(
    plug: {TCK.Router, %{auth: auth_opts, plug: plug_opts}},
    port: port,
    startup_log: false
  )

IO.puts("TCK server running on #{base_url}")
IO.puts("Agent card: #{base_url}/.well-known/agent-card.json")
IO.puts("Press Ctrl+C to stop")

Process.sleep(:infinity)
