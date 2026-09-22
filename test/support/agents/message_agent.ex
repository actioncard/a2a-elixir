defmodule A2A.Test.MessageAgent do
  @moduledoc false
  use A2A.Agent,
    name: "message-agent",
    description: "Answers out-of-band with a bare message instead of a task",
    skills: [
      %{
        id: "direct",
        name: "Direct",
        description: "Replies without creating a task",
        tags: ["test"]
      }
    ]

  # "start" opens a task so the continue path is reachable; everything else
  # answers with a bare Message and leaves no task behind.
  @impl A2A.Agent
  def handle_message(message, _context) do
    case A2A.Message.text(message) do
      "start" -> {:input_required, [A2A.Part.Text.new("What next?")]}
      text -> {:message, [A2A.Part.Text.new("Direct: #{text}")]}
    end
  end
end
