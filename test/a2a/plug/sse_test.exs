defmodule A2A.Plug.SSETest do
  use ExUnit.Case, async: true

  @moduletag :plug

  defp plug_opts(agent) do
    A2A.Plug.init(agent: agent, base_url: "http://localhost:4000")
  end

  defp stream_conn(params, agent) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "message/stream",
        "params" => params
      })

    Plug.Test.conn(:post, "/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> A2A.Plug.call(plug_opts(agent))
  end

  defp message_params(text \\ "hello") do
    %{
      "message" => %{
        "messageId" => "msg-test",
        "role" => "user",
        "parts" => [%{"kind" => "text", "text" => text}]
      }
    }
  end

  defp parse_sse_events(conn) do
    conn.resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn line ->
      line
      |> String.trim_leading("data: ")
      |> Jason.decode!()
    end)
  end

  setup do
    agent = start_supervised!({A2A.Test.StreamAgent, [name: nil]})
    {:ok, agent: agent}
  end

  describe "message/stream" do
    test "returns text/event-stream content type", %{agent: agent} do
      conn = stream_conn(message_params(), agent)

      assert conn.status == 200

      content_type =
        for({k, v} <- conn.resp_headers, k == "content-type", do: v) |> hd()

      assert content_type == "text/event-stream"
    end

    test "first event is task snapshot", %{agent: agent} do
      conn = stream_conn(message_params(), agent)
      [first | _] = parse_sse_events(conn)

      assert first["jsonrpc"] == "2.0"
      assert first["id"] == 1
      assert first["result"]["kind"] == "task"
    end

    test "middle events are artifact updates", %{agent: agent} do
      conn = stream_conn(message_params(), agent)
      events = parse_sse_events(conn)

      # StreamAgent produces 3 chunks, so events 2-4 are artifact updates
      artifact_events = Enum.slice(events, 1..3)

      for event <- artifact_events do
        assert event["result"]["kind"] == "artifact-update"
        assert event["result"]["taskId"]
        assert event["result"]["artifact"]["parts"]
      end
    end

    test "last event is status update with final: true", %{agent: agent} do
      conn = stream_conn(message_params(), agent)
      events = parse_sse_events(conn)
      last = List.last(events)

      assert last["result"]["kind"] == "status-update"
      assert last["result"]["final"] == true
      assert last["result"]["status"]["state"] == "TASK_STATE_COMPLETED"
    end

    test "all events are valid JSON-RPC envelopes", %{agent: agent} do
      conn = stream_conn(message_params(), agent)
      events = parse_sse_events(conn)

      for event <- events do
        assert event["jsonrpc"] == "2.0"
        assert event["id"] == 1
        assert is_map(event["result"])
      end
    end
  end

  describe "metadata in stream" do
    test "init metadata flows through to streamed task", %{agent: agent} do
      opts =
        A2A.Plug.init(
          agent: agent,
          base_url: "http://localhost:4000",
          metadata: %{"env" => "prod"}
        )

      params =
        message_params()
        |> Map.put("metadata", %{"request_key" => "val"})

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "message/stream",
          "params" => params
        })

      conn =
        Plug.Test.conn(:post, "/", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> A2A.Plug.put_metadata(%{"tenant_id" => "t-1"})
        |> A2A.Plug.call(opts)

      [first | _] = parse_sse_events(conn)
      task_meta = first["result"]["metadata"]
      assert task_meta["env"] == "prod"
      assert task_meta["tenant_id"] == "t-1"
      assert task_meta["request_key"] == "val"
    end
  end

  describe "stream error handling" do
    test "non-streaming agent returns JSON-RPC error" do
      agent = start_supervised!({A2A.Test.ErrorAgent, [name: nil]})
      conn = stream_conn(message_params(), agent)

      # ErrorAgent returns {:error, _}, so A2A.stream returns
      # {:error, {:not_streaming, _}}. Should get a JSON error response.
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == -32_603
    end

    test "stream that raises sends final failed status" do
      agent = start_supervised!({A2A.Test.CrashingStreamAgent, [name: nil]})
      conn = stream_conn(message_params(), agent)
      events = parse_sse_events(conn)

      last = List.last(events)
      assert last["result"]["kind"] == "status-update"
      assert last["result"]["final"] == true
      assert last["result"]["status"]["state"] == "TASK_STATE_FAILED"
    end
  end
end
