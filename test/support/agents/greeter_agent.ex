defmodule A2A.Test.GreeterAgent do
  @moduledoc false
  use A2A.Agent,
    name: "greeter",
    description: "Greets users by name",
    skills: [
      %{id: "greet", name: "Greet", description: "Says hello", tags: ["greeting"]}
    ]

  @impl A2A.Agent
  def handle_message(message, _context) do
    text = A2A.Message.text(message) || "stranger"
    {:reply, [A2A.Part.Text.new("Hello, #{text}!")]}
  end
end
