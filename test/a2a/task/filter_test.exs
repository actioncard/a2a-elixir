defmodule A2A.Task.FilterTest do
  use ExUnit.Case, async: true

  alias A2A.Task
  alias A2A.Task.Filter
  alias A2A.Task.Status

  # Helpers -----------------------------------------------------------------

  defp make_task(id, state, opts \\ []) do
    ts = Keyword.get(opts, :timestamp, DateTime.utc_now())
    ctx = Keyword.get(opts, :context_id)
    history = Keyword.get(opts, :history, [])
    artifacts = Keyword.get(opts, :artifacts, [])

    %Task{
      id: id,
      context_id: ctx,
      status: %Status{state: state, timestamp: ts, message: nil},
      history: history,
      artifacts: artifacts,
      metadata: %{}
    }
  end

  defp ts(offset_seconds) do
    DateTime.add(~U[2026-01-01 00:00:00Z], offset_seconds, :second)
  end

  # Tests -------------------------------------------------------------------

  describe "apply/2 with no filters" do
    test "returns all tasks sorted by timestamp descending" do
      tasks = [
        make_task("a", :working, timestamp: ts(1)),
        make_task("b", :completed, timestamp: ts(3)),
        make_task("c", :submitted, timestamp: ts(2))
      ]

      assert {:ok, result} = Filter.apply(tasks)
      assert Enum.map(result.tasks, & &1.id) == ["b", "c", "a"]
      assert result.total_size == 3
      assert result.page_size == 3
      assert result.next_page_token == ""
    end

    test "returns empty result for empty list" do
      assert {:ok, result} = Filter.apply([])
      assert result.tasks == []
      assert result.total_size == 0
      assert result.page_size == 0
    end
  end

  describe "context_id filter" do
    test "filters tasks by context_id" do
      tasks = [
        make_task("a", :working, context_id: "ctx-1", timestamp: ts(1)),
        make_task("b", :working, context_id: "ctx-2", timestamp: ts(2)),
        make_task("c", :working, context_id: "ctx-1", timestamp: ts(3))
      ]

      assert {:ok, result} = Filter.apply(tasks, context_id: "ctx-1")
      assert Enum.map(result.tasks, & &1.id) == ["c", "a"]
      assert result.total_size == 2
    end

    test "returns nothing when context_id matches no tasks" do
      tasks = [make_task("a", :working, context_id: "ctx-1", timestamp: ts(1))]
      assert {:ok, result} = Filter.apply(tasks, context_id: "ctx-999")
      assert result.tasks == []
      assert result.total_size == 0
    end
  end

  describe "status filter" do
    test "filters tasks by state" do
      tasks = [
        make_task("a", :working, timestamp: ts(1)),
        make_task("b", :completed, timestamp: ts(2)),
        make_task("c", :working, timestamp: ts(3))
      ]

      assert {:ok, result} = Filter.apply(tasks, status: :completed)
      assert length(result.tasks) == 1
      assert hd(result.tasks).id == "b"
    end
  end

  describe "status_timestamp_after filter" do
    test "filters tasks updated after a given timestamp" do
      tasks = [
        make_task("a", :working, timestamp: ts(10)),
        make_task("b", :working, timestamp: ts(20)),
        make_task("c", :working, timestamp: ts(30))
      ]

      assert {:ok, result} = Filter.apply(tasks, status_timestamp_after: ts(15))
      ids = Enum.map(result.tasks, & &1.id)
      assert "b" in ids
      assert "c" in ids
      refute "a" in ids
    end
  end

  describe "pagination" do
    test "limits results to page_size" do
      tasks = for i <- 1..10, do: make_task("t-#{i}", :working, timestamp: ts(i))

      assert {:ok, result} = Filter.apply(tasks, page_size: 3)
      assert result.page_size == 3
      assert result.total_size == 10
      assert result.next_page_token != ""
    end

    test "returns empty next_page_token on last page" do
      tasks = [
        make_task("a", :working, timestamp: ts(1)),
        make_task("b", :working, timestamp: ts(2))
      ]

      assert {:ok, result} = Filter.apply(tasks, page_size: 5)
      assert result.next_page_token == ""
    end

    test "page_token starts after the matching task" do
      tasks = for i <- 1..5, do: make_task("t-#{i}", :working, timestamp: ts(i))

      # First page
      assert {:ok, page1} = Filter.apply(tasks, page_size: 2)
      # Sorted desc by timestamp: t-5, t-4, t-3, t-2, t-1
      assert length(page1.tasks) == 2
      token = page1.next_page_token

      # Second page using the token
      assert {:ok, page2} = Filter.apply(tasks, page_size: 2, page_token: token)
      assert length(page2.tasks) == 2

      # No overlap between pages
      page1_ids = Enum.map(page1.tasks, & &1.id) |> MapSet.new()
      page2_ids = Enum.map(page2.tasks, & &1.id) |> MapSet.new()
      assert MapSet.disjoint?(page1_ids, page2_ids)
    end

    test "invalid page_token returns error" do
      tasks = [make_task("a", :working, timestamp: ts(1))]
      assert {:error, :invalid_page_token} = Filter.apply(tasks, page_token: "nonexistent-id")
    end

    test "empty string page_token is treated as no token" do
      tasks = [make_task("a", :working, timestamp: ts(1))]
      assert {:ok, _result} = Filter.apply(tasks, page_token: "")
    end
  end

  describe "history_length" do
    test "truncates history to specified length" do
      history = [
        A2A.Message.new_user("msg 1"),
        A2A.Message.new_agent("msg 2"),
        A2A.Message.new_user("msg 3")
      ]

      tasks = [make_task("a", :working, timestamp: ts(1), history: history)]

      assert {:ok, result} = Filter.apply(tasks, history_length: 1)
      [task] = result.tasks
      assert length(task.history) == 1
    end

    test "default history_length of 0 clears history" do
      history = [A2A.Message.new_user("msg")]
      tasks = [make_task("a", :working, timestamp: ts(1), history: history)]

      assert {:ok, result} = Filter.apply(tasks)
      [task] = result.tasks
      assert task.history == []
    end
  end

  describe "include_artifacts" do
    test "strips artifacts by default" do
      artifact = A2A.Artifact.new([A2A.Part.Text.new("output")])
      tasks = [make_task("a", :completed, timestamp: ts(1), artifacts: [artifact])]

      assert {:ok, result} = Filter.apply(tasks)
      [task] = result.tasks
      assert task.artifacts == []
    end

    test "preserves artifacts when include_artifacts is true" do
      artifact = A2A.Artifact.new([A2A.Part.Text.new("output")])
      tasks = [make_task("a", :completed, timestamp: ts(1), artifacts: [artifact])]

      assert {:ok, result} = Filter.apply(tasks, include_artifacts: true)
      [task] = result.tasks
      assert length(task.artifacts) == 1
    end
  end

  describe "combined filters" do
    test "applies context_id + status + pagination together" do
      tasks = [
        make_task("a", :working, context_id: "ctx", timestamp: ts(1)),
        make_task("b", :completed, context_id: "ctx", timestamp: ts(2)),
        make_task("c", :working, context_id: "ctx", timestamp: ts(3)),
        make_task("d", :working, context_id: "other", timestamp: ts(4)),
        make_task("e", :working, context_id: "ctx", timestamp: ts(5))
      ]

      assert {:ok, result} =
               Filter.apply(tasks, context_id: "ctx", status: :working, page_size: 2)

      # ctx + working: e (ts5), c (ts3), a (ts1) -> page_size 2 -> [e, c]
      assert Enum.map(result.tasks, & &1.id) == ["e", "c"]
      assert result.total_size == 3
      assert result.page_size == 2
      assert result.next_page_token != ""
    end
  end
end
