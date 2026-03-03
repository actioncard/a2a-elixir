defmodule A2A.Agent.StateTest do
  use ExUnit.Case, async: true

  alias A2A.Agent.State
  alias A2A.Task

  defp make_task(id, state, opts) do
    ts = Keyword.get(opts, :timestamp, DateTime.utc_now())
    ctx = Keyword.get(opts, :context_id)
    metadata = Keyword.get(opts, :metadata, %{})

    %Task{
      id: id,
      context_id: ctx,
      status: %Task.Status{state: state, timestamp: ts},
      history: Keyword.get(opts, :history, []),
      artifacts: [],
      metadata: metadata
    }
  end

  defp state_with_tasks(tasks) do
    task_map = Map.new(tasks, &{&1.id, &1})
    %State{module: nil, tasks: task_map, contexts: %{}}
  end

  describe "list_tasks/2" do
    test "returns tasks sorted by timestamp descending" do
      t1 = make_task("a", :completed, timestamp: ~U[2025-01-01 00:00:00Z])
      t2 = make_task("b", :working, timestamp: ~U[2025-01-03 00:00:00Z])
      t3 = make_task("c", :submitted, timestamp: ~U[2025-01-02 00:00:00Z])
      state = state_with_tasks([t1, t2, t3])

      {:ok, result} = State.list_tasks(state, %{})

      ids = Enum.map(result.tasks, & &1.id)
      assert ids == ["b", "c", "a"]
    end

    test "page_size in response reflects actual task count" do
      t1 = make_task("a", :completed, timestamp: ~U[2025-01-01 00:00:00Z])
      t2 = make_task("b", :working, timestamp: ~U[2025-01-02 00:00:00Z])
      state = state_with_tasks([t1, t2])

      {:ok, result} = State.list_tasks(state, %{"pageSize" => 50})

      assert result.page_size == 2
    end

    test "page_size in response is capped by actual results" do
      tasks =
        for i <- 1..5 do
          ts = DateTime.add(~U[2025-01-01 00:00:00Z], i, :second)
          make_task("t#{i}", :completed, timestamp: ts)
        end

      state = state_with_tasks(tasks)

      {:ok, result} = State.list_tasks(state, %{"pageSize" => 3})

      assert result.page_size == 3
      assert length(result.tasks) == 3
    end

    test "filters by status atom correctly" do
      t1 = make_task("a", :completed, timestamp: ~U[2025-01-01 00:00:00Z])
      t2 = make_task("b", :working, timestamp: ~U[2025-01-02 00:00:00Z])
      state = state_with_tasks([t1, t2])

      {:ok, result} =
        State.list_tasks(state, %{"status" => "TASK_STATE_WORKING"})

      assert length(result.tasks) == 1
      assert hd(result.tasks).id == "b"
    end

    test "unknown status returns empty results" do
      t1 = make_task("a", :completed, timestamp: ~U[2025-01-01 00:00:00Z])
      state = state_with_tasks([t1])

      {:ok, result} =
        State.list_tasks(state, %{"status" => "TASK_STATE_UNKNOWN"})

      assert result.tasks == []
    end
  end
end
