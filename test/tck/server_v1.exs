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

  # The TCK dispatches on the `messageId` prefix, not the message body — it sends
  # identical text for every artifact case (see .tck/sut/a2a-python/sut_agent.py).
  # Artifact cases must answer `{:reply, …}`: `{:stream, …}` is only drained on the
  # SSE path, so on a synchronous `message/send` it yields no artifact at all.
  @impl A2A.Agent
  def handle_message(message, _context) do
    text = A2A.Message.text(message) || ""
    message_id = message.message_id || ""

    cond do
      String.starts_with?(message_id, "tck-artifact-text") ->
        {:reply, [A2A.Part.Text.new("Generated text content")]}

      # Must precede "tck-artifact-file", which is a prefix of this one.
      String.starts_with?(message_id, "tck-artifact-file-url") ->
        file =
          A2A.FileContent.from_uri("https://example.com/output.txt",
            name: "output.txt",
            mime_type: "text/plain"
          )

        {:reply, [A2A.Part.File.new(file)]}

      String.starts_with?(message_id, "tck-artifact-file") ->
        file = A2A.FileContent.from_bytes("tck", name: "output.txt", mime_type: "text/plain")

        {:reply, [A2A.Part.File.new(file)]}

      String.starts_with?(message_id, "tck-artifact-data") ->
        {:reply, [A2A.Part.Data.new(%{"key" => "value", "count" => 42})]}

      # Lifecycle prefixes: the task-history and task-lifecycle suites build a
      # fixture task with these and skip unless it reaches the expected state.
      String.starts_with?(message_id, "tck-complete-task") ->
        {:reply, [A2A.Part.Text.new("Hello from TCK")]}

      String.starts_with?(message_id, "tck-input-required") ->
        {:input_required, [A2A.Part.Text.new("Please provide additional input")]}

      # The bare-Message half of the SendMessageResponse oneof: the TCK reads
      # `result["message"]`, so this must not be wrapped in a task.
      String.starts_with?(message_id, "tck-message-response") ->
        {:message, [A2A.Part.Text.new("Direct message response")]}

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
    plug:
      {A2A.Plug,
       [
         agent: TCK.Agent,
         base_url: base_url,
         # A2A.Plug's capability gates read agent_card_opts directly, the same
         # source encode_agent_card/2 publishes from, so this cannot advertise a
         # capability the server then refuses.
         agent_card_opts: [capabilities: %{streaming: true, push_notifications: true}]
       ]},
    port: port,
    startup_log: false
  )

IO.puts("TCK v1 server running on #{base_url}")
IO.puts("Agent card: #{base_url}/.well-known/agent-card.json")
IO.puts("Press Ctrl+C to stop")

Process.sleep(:infinity)
