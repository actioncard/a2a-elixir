defmodule A2A.AgentTest do
  use ExUnit.Case, async: true

  describe "use A2A.Agent with options" do
    test "generates agent_card/0 from use options" do
      card = A2A.Test.EchoAgent.agent_card()
      assert card.name == "echo"
      assert card.description == "Echoes messages back"
      assert card.version == "0.1.0"
      assert [%{id: "echo", name: "Echo"}] = card.skills
    end

    test "default handle_cancel/1 returns :ok" do
      context = %{task_id: "t-1", context_id: nil, history: []}
      assert :ok = A2A.Test.EchoAgent.handle_cancel(context)
    end

    test "handle_message/2 works" do
      msg = A2A.Message.new_user("hello")
      ctx = %{task_id: "t-1", context_id: nil, history: []}

      assert {:reply, [%A2A.Part.Text{text: "hello"}]} =
               A2A.Test.EchoAgent.handle_message(msg, ctx)
    end
  end

  describe "use A2A.Agent without options" do
    defmodule ManualCardAgent do
      @moduledoc false
      use A2A.Agent

      @impl A2A.Agent
      def agent_card do
        %{
          name: "manual",
          description: "Manually defined card",
          version: "2.0.0",
          skills: [],
          opts: []
        }
      end

      @impl A2A.Agent
      def handle_message(_message, _context) do
        {:reply, [A2A.Part.Text.new("manual")]}
      end
    end

    test "allows manual agent_card/0 definition" do
      assert ManualCardAgent.agent_card().name == "manual"
      assert ManualCardAgent.agent_card().version == "2.0.0"
    end
  end
end
