defmodule A2A.Test.CrashingStreamAgent do
  @moduledoc false
  use A2A.Agent,
    name: "crashing-stream",
    description: "Streams one part then raises",
    skills: []

  @impl A2A.Agent
  def handle_message(_message, _context) do
    stream =
      Stream.map(1..3, fn
        1 -> A2A.Part.Text.new("chunk 1")
        2 -> raise "stream exploded"
        _ -> A2A.Part.Text.new("unreachable")
      end)

    {:stream, stream}
  end
end
