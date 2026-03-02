defmodule A2ATest do
  use ExUnit.Case, async: true

  describe "A2A.call/3" do
    setup do
      pid = start_supervised!({A2A.Test.EchoAgent, name: :"api_#{System.unique_integer()}"})
      %{pid: pid}
    end

    test "accepts a string message", %{pid: pid} do
      assert {:ok, task} = A2A.call(pid, "hello")
      assert task.status.state == :completed
      assert [%A2A.Artifact{parts: [%A2A.Part.Text{text: "hello"}]}] = task.artifacts
    end

    test "accepts an A2A.Message", %{pid: pid} do
      msg = A2A.Message.new_user("world")
      assert {:ok, task} = A2A.call(pid, msg)
      assert task.status.state == :completed
    end

    test "passes context_id option", %{pid: pid} do
      assert {:ok, task} = A2A.call(pid, "ctx", context_id: "ctx-42")
      assert task.context_id == "ctx-42"
    end
  end

  describe "A2A.stream/3" do
    setup do
      pid = start_supervised!({A2A.Test.StreamAgent, name: :"stream_#{System.unique_integer()}"})
      %{pid: pid}
    end

    test "returns task and stream for streaming agents", %{pid: pid} do
      assert {:ok, task, stream} = A2A.stream(pid, "go")
      assert task.status.state == :working
      parts = Enum.to_list(stream)
      assert length(parts) == 3
      assert Enum.all?(parts, &match?(%A2A.Part.Text{}, &1))

      # After stream is consumed, task should transition to :completed
      # Give the cast a moment to process
      Process.sleep(10)
      {:ok, completed} = A2A.Test.StreamAgent.get_task(pid, task.id)
      assert completed.status.state == :completed
      assert length(completed.artifacts) == 1
    end
  end

  describe "A2A.call/3 multi-turn" do
    setup do
      pid =
        start_supervised!({A2A.Test.MultiTurnAgent, name: :"mt_api_#{System.unique_integer()}"})

      %{pid: pid}
    end

    test "full multi-turn conversation via public API", %{pid: pid} do
      {:ok, task} = A2A.call(pid, "pizza")
      assert task.status.state == :input_required

      {:ok, task} = A2A.call(pid, "large", task_id: task.id)
      assert task.status.state == :completed
      assert task.id == task.id
    end
  end

  describe "A2A.call/3 timeout" do
    setup do
      pid =
        start_supervised!({A2A.Test.SlowAgent, name: :"slow_#{System.unique_integer()}"})

      %{pid: pid}
    end

    test "works with explicit :timeout option", %{pid: pid} do
      assert {:ok, task} = A2A.call(pid, "hello", timeout: 10_000)
      assert task.status.state == :completed
    end

    test "raises on too-short timeout", %{pid: pid} do
      assert catch_exit(A2A.call(pid, "hello", timeout: 1))
    end
  end

  describe "A2A.get_agent_card/2" do
    setup do
      pid =
        start_supervised!({A2A.Test.EchoAgent, name: :"card_#{System.unique_integer()}"})

      %{pid: pid}
    end

    test "returns encoded card map with base_url", %{pid: pid} do
      card = A2A.get_agent_card(pid, base_url: "https://example.com/a2a")

      assert card["name"] == "echo"
      assert card["url"] == "https://example.com/a2a"
      assert is_list(card["skills"])
    end

    test "forwards extra opts to encode_agent_card", %{pid: pid} do
      card =
        A2A.get_agent_card(pid,
          base_url: "https://example.com",
          capabilities: %{streaming: true}
        )

      assert card["capabilities"]["streaming"] == true
    end

    test "raises without base_url" do
      assert_raise KeyError, ~r/:base_url/, fn ->
        A2A.get_agent_card(self(), [])
      end
    end
  end

  describe "A2A.stream/3 with non-streaming agent" do
    setup do
      pid = start_supervised!({A2A.Test.EchoAgent, name: :"ns_#{System.unique_integer()}"})
      %{pid: pid}
    end

    test "returns error for non-streaming agents", %{pid: pid} do
      assert {:error, {:not_streaming, _task}} = A2A.stream(pid, "hello")
    end
  end
end
