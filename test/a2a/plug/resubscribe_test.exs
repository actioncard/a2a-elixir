defmodule A2A.Plug.ResubscribeTest do
  use ExUnit.Case, async: true

  @moduletag :plug

  defp plug_opts(agent, extra) do
    A2A.Plug.init(
      [
        agent: agent,
        base_url: "http://localhost:4000",
        agent_card_opts: [capabilities: %{streaming: true}]
      ] ++ extra
    )
  end

  # The subscribe handler blocks until the task is terminal, so the request has
  # to run somewhere other than the process driving the task forward.
  defp subscribe_async(task_id, opts) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tasks/resubscribe",
        "params" => %{"id" => task_id}
      })

    Task.async(fn ->
      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> A2A.Plug.call(opts)
    end)
  end

  defp parse_sse_events(conn) do
    conn.resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.map(&(&1 |> String.trim_leading("data: ") |> Jason.decode!()))
  end

  defp await_subscription(agent, task_id) do
    if A2A.Agent.State.subscribers_for(:sys.get_state(agent), task_id) == [] do
      Process.sleep(10)
      await_subscription(agent, task_id)
    else
      :ok
    end
  end

  describe "live relay" do
    test "opens with a task snapshot and closes at the terminal state" do
      agent = start_supervised!({A2A.Test.MultiTurnAgent, [name: nil]})
      opts = plug_opts(agent, resubscribe_timeout: 2_000)

      {:ok, task} = A2A.call(agent, "order")
      subscriber = subscribe_async(task.id, opts)
      await_subscription(agent, task.id)

      {:ok, _completed} = A2A.call(agent, "large", task_id: task.id)

      conn = Task.await(subscriber, 5_000)
      assert conn.status == 200
      assert [first | rest] = parse_sse_events(conn)

      # STREAM-SUB-001: the opening event is the task as it stands.
      assert first["result"]["task"]["id"] == task.id
      assert first["result"]["task"]["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"

      # STREAM-SUB-002: the stream carries the transition and then ends.
      assert %{"statusUpdate" => update} = List.last(rest)["result"]
      assert update["status"]["state"] == "TASK_STATE_COMPLETED"
      assert update["taskId"] == task.id
    end

    test "two subscribers both see the transition" do
      agent = start_supervised!({A2A.Test.MultiTurnAgent, [name: nil]})
      opts = plug_opts(agent, resubscribe_timeout: 2_000)

      {:ok, task} = A2A.call(agent, "order")
      first = subscribe_async(task.id, opts)
      second = subscribe_async(task.id, opts)
      await_subscription(agent, task.id)

      {:ok, _} = A2A.call(agent, "large", task_id: task.id)

      for subscriber <- [first, second] do
        events = subscriber |> Task.await(5_000) |> parse_sse_events()
        assert %{"statusUpdate" => update} = List.last(events)["result"]
        assert update["status"]["state"] == "TASK_STATE_COMPLETED"
      end
    end

    test "closes on the idle timeout when the task never finishes" do
      agent = start_supervised!({A2A.Test.MultiTurnAgent, [name: nil]})
      opts = plug_opts(agent, resubscribe_timeout: 150)

      {:ok, task} = A2A.call(agent, "order")
      conn = task.id |> subscribe_async(opts) |> Task.await(5_000)

      # Only the snapshot: a task that never terminates must not pin the
      # connection process open forever.
      assert [_snapshot] = parse_sse_events(conn)
    end
  end

  describe "the stored stream is never replayed" do
    test "subscribing does not enumerate the agent's stream" do
      agent = start_supervised!({A2A.Test.StreamAgent, [name: nil]})
      opts = plug_opts(agent, resubscribe_timeout: 150)

      {:ok, task} = A2A.call(agent, "go")
      assert task.status.state == :working
      assert Map.has_key?(task.metadata, :stream)

      conn = task.id |> subscribe_async(opts) |> Task.await(5_000)

      # Enumerating metadata[:stream] would replay the agent's output from the
      # start and cast a second {:stream_done, …}, appending a duplicate
      # artifact and history entry. The snapshot must stay inert.
      assert [snapshot] = parse_sse_events(conn)
      refute Map.has_key?(snapshot["result"]["task"], "artifacts")

      {:ok, stored} = GenServer.call(agent, {:get_task, task.id})
      assert stored.artifacts == []
      assert length(stored.history) == 1
      assert stored.status.state == :working
    end
  end

  describe "subscriber cleanup" do
    test "a dead subscriber is unregistered" do
      agent = start_supervised!({A2A.Test.MultiTurnAgent, [name: nil]})
      opts = plug_opts(agent, resubscribe_timeout: 5_000)

      {:ok, task} = A2A.call(agent, "order")
      subscriber = subscribe_async(task.id, opts)
      await_subscription(agent, task.id)

      Task.shutdown(subscriber, :brutal_kill)

      # The monitor is the only cleanup path, so a dropped connection has to
      # deregister itself without the agent being told.
      wait_until(fn ->
        A2A.Agent.State.subscribers_for(:sys.get_state(agent), task.id) == []
      end)

      # The agent stays healthy and the task still completes normally.
      assert {:ok, completed} = A2A.call(agent, "large", task_id: task.id)
      assert completed.status.state == :completed
    end

    test "subscribers are dropped once the task is terminal" do
      agent = start_supervised!({A2A.Test.MultiTurnAgent, [name: nil]})
      opts = plug_opts(agent, resubscribe_timeout: 2_000)

      {:ok, task} = A2A.call(agent, "order")
      subscriber = subscribe_async(task.id, opts)
      await_subscription(agent, task.id)

      {:ok, _} = A2A.call(agent, "large", task_id: task.id)
      Task.await(subscriber, 5_000)

      assert :sys.get_state(agent).subscribers == %{}
    end
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end
end
