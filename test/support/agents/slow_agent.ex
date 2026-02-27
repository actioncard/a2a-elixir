defmodule A2A.Test.SlowAgent do
  @moduledoc false
  use A2A.Agent,
    name: "slow",
    description: "Responds after a delay"

  @impl A2A.Agent
  def handle_message(message, _context) do
    Process.sleep(200)
    text = A2A.Message.text(message) || ""
    {:reply, [A2A.Part.Text.new(text)]}
  end
end
