defmodule A2A.Agent.RuntimeTest do
  use ExUnit.Case, async: true

  alias A2A.Message

  describe "EchoAgent runtime" do
    setup do
      pid = start_supervised!({A2A.Test.EchoAgent, name: :"echo_#{System.unique_integer()}"})
      %{pid: pid}
    end

    test "call/2 returns a completed task", %{pid: pid} do
      msg = Message.new_user("hello")
      assert {:ok, task} = A2A.Test.EchoAgent.call(pid, msg)
      assert task.status.state == :completed
      assert String.starts_with?(task.id, "tsk-")
      assert [%A2A.Artifact{parts: [%A2A.Part.Text{text: "hello"}]}] = task.artifacts
    end

    test "call/2 records message history", %{pid: pid} do
      msg = Message.new_user("test")
      {:ok, task} = A2A.Test.EchoAgent.call(pid, msg)
      assert length(task.history) == 2
      assert hd(task.history).role == :user
      assert List.last(task.history).role == :agent
    end

    test "get_task/2 retrieves a stored task", %{pid: pid} do
      msg = Message.new_user("stored")
      {:ok, task} = A2A.Test.EchoAgent.call(pid, msg)
      assert {:ok, ^task} = A2A.Test.EchoAgent.get_task(pid, task.id)
    end

    test "get_task/2 returns error for unknown task", %{pid: pid} do
      assert {:error, :not_found} = A2A.Test.EchoAgent.get_task(pid, "tsk-nonexistent")
    end
  end

  describe "ErrorAgent runtime" do
    setup do
      pid = start_supervised!({A2A.Test.ErrorAgent, name: :"err_#{System.unique_integer()}"})
      %{pid: pid}
    end

    test "call/2 returns a failed task", %{pid: pid} do
      msg = Message.new_user("fail")
      assert {:ok, task} = A2A.Test.ErrorAgent.call(pid, msg)
      assert task.status.state == :failed
    end
  end

  describe "MultiTurnAgent runtime" do
    setup do
      name = :"mt_#{System.unique_integer()}"
      pid = start_supervised!({A2A.Test.MultiTurnAgent, name: name})
      %{pid: pid}
    end

    test "first message returns input_required", %{pid: pid} do
      msg = Message.new_user("pizza")
      assert {:ok, task} = A2A.Test.MultiTurnAgent.call(pid, msg)
      assert task.status.state == :input_required
      assert task.status.message.role == :agent
    end

    test "continuing a task resumes with accumulated history", %{pid: pid} do
      msg1 = Message.new_user("pizza")
      {:ok, task1} = A2A.Test.MultiTurnAgent.call(pid, msg1)
      assert task1.status.state == :input_required

      # Continue the same task with a follow-up
      msg2 = Message.new_user("large")
      {:ok, task2} = A2A.Test.MultiTurnAgent.call(pid, msg2, task_id: task1.id)
      assert task2.status.state == :completed
      assert task2.id == task1.id

      # History should have: user msg1, agent "What size?", user msg2, agent reply
      assert length(task2.history) == 4
      assert Enum.at(task2.history, 0).role == :user
      assert Enum.at(task2.history, 1).role == :agent
      assert Enum.at(task2.history, 2).role == :user
      assert Enum.at(task2.history, 3).role == :agent
    end

    test "continuing a completed task returns error", %{pid: pid} do
      msg1 = Message.new_user("pizza")
      {:ok, task1} = A2A.Test.MultiTurnAgent.call(pid, msg1)

      msg2 = Message.new_user("large")
      {:ok, task2} = A2A.Test.MultiTurnAgent.call(pid, msg2, task_id: task1.id)
      assert task2.status.state == :completed

      # Can't continue a completed task
      msg3 = Message.new_user("extra cheese")

      assert {:error, :not_continuable} =
               A2A.Test.MultiTurnAgent.call(pid, msg3, task_id: task2.id)
    end

    test "continuing a non-existent task returns not_found", %{pid: pid} do
      msg = Message.new_user("hello")

      assert {:error, :not_found} =
               A2A.Test.MultiTurnAgent.call(pid, msg, task_id: "tsk-fake")
    end
  end

  describe "cancel" do
    setup do
      pid = start_supervised!({A2A.Test.EchoAgent, name: :"cancel_#{System.unique_integer()}"})
      %{pid: pid}
    end

    test "cancel/2 returns not_cancelable for completed task", %{pid: pid} do
      msg = Message.new_user("to cancel")
      {:ok, task} = A2A.Test.EchoAgent.call(pid, msg)
      assert task.status.state == :completed
      assert {:error, :not_cancelable} = A2A.Test.EchoAgent.cancel(pid, task.id)
    end

    test "cancel/2 returns error for unknown task", %{pid: pid} do
      assert {:error, :not_found} = A2A.Test.EchoAgent.cancel(pid, "tsk-nope")
    end
  end

  describe "context_id tracking" do
    setup do
      pid = start_supervised!({A2A.Test.EchoAgent, name: :"ctx_#{System.unique_integer()}"})
      %{pid: pid}
    end

    test "tasks with context_id are tracked", %{pid: pid} do
      msg = Message.new_user("ctx test")
      {:ok, task} = A2A.Test.EchoAgent.call(pid, msg, context_id: "ctx-1")
      assert task.context_id == "ctx-1"
    end
  end

  describe "with TaskStore" do
    setup do
      table = :"store_rt_#{System.unique_integer([:positive])}"
      start_supervised!({A2A.TaskStore.ETS, name: table})

      pid =
        start_supervised!(
          {A2A.Test.EchoAgent,
           name: :"stored_#{System.unique_integer()}", task_store: {A2A.TaskStore.ETS, table}}
        )

      %{pid: pid, table: table}
    end

    test "tasks are persisted to external store", %{pid: pid, table: table} do
      msg = Message.new_user("persist me")
      {:ok, task} = A2A.Test.EchoAgent.call(pid, msg)
      assert {:ok, stored} = A2A.TaskStore.ETS.get(table, task.id)
      assert stored.id == task.id
      assert stored.status.state == :completed
    end
  end
end
