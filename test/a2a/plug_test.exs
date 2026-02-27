defmodule A2A.PlugTest do
  use ExUnit.Case, async: true

  @moduletag :plug

  defp plug_opts(agent, extra \\ []) do
    A2A.Plug.init([agent: agent, base_url: "http://localhost:4000"] ++ extra)
  end

  defp json_rpc_conn(method, params \\ %{}, id \\ 1) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      })

    Plug.Test.conn(:post, "/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  defp message_params(text \\ "hello") do
    %{
      "message" => %{
        "role" => "user",
        "parts" => [%{"kind" => "text", "text" => text}]
      }
    }
  end

  defp json_body(conn) do
    Jason.decode!(conn.resp_body)
  end

  setup do
    agent = start_supervised!(A2A.Test.EchoAgent)
    {:ok, agent: agent}
  end

  # -- Agent card --------------------------------------------------------------

  describe "agent card" do
    test "GET returns 200 with agent card JSON", %{agent: agent} do
      conn =
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> A2A.Plug.call(plug_opts(agent))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"

      body = json_body(conn)
      assert body["name"] == "echo"
      assert body["url"] == "http://localhost:4000"
      assert is_list(body["skills"])
    end

    test "POST to agent card path returns 405", %{agent: agent} do
      conn =
        Plug.Test.conn(:post, "/.well-known/agent-card.json")
        |> A2A.Plug.call(plug_opts(agent))

      assert conn.status == 405
      assert get_resp_header(conn, "allow") |> hd() == "GET"
    end

    test "PUT to agent card path returns 405", %{agent: agent} do
      conn =
        Plug.Test.conn(:put, "/.well-known/agent-card.json")
        |> A2A.Plug.call(plug_opts(agent))

      assert conn.status == 405
    end
  end

  # -- Custom paths ------------------------------------------------------------

  describe "custom paths" do
    test "routes to custom agent_card_path", %{agent: agent} do
      opts = plug_opts(agent, agent_card_path: ["agent.json"])

      conn =
        Plug.Test.conn(:get, "/agent.json")
        |> A2A.Plug.call(opts)

      assert conn.status == 200
      assert json_body(conn)["name"] == "echo"
    end

    test "routes to custom json_rpc_path", %{agent: agent} do
      opts = plug_opts(agent, json_rpc_path: ["rpc"])

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "message/send",
          "params" => message_params()
        })

      conn =
        Plug.Test.conn(:post, "/rpc", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> A2A.Plug.call(opts)

      assert conn.status == 200
      assert json_body(conn)["result"]["kind"] == "task"
    end
  end

  # -- message/send ------------------------------------------------------------

  describe "message/send" do
    test "valid request returns completed task", %{agent: agent} do
      conn =
        json_rpc_conn("message/send", message_params())
        |> A2A.Plug.call(plug_opts(agent))

      assert conn.status == 200

      body = json_body(conn)
      assert body["jsonrpc"] == "2.0"
      assert body["id"] == 1
      assert body["result"]["kind"] == "task"
      assert body["result"]["status"]["state"] == "completed"
    end

    test "works with pre-parsed body (Phoenix/Plug.Parsers)", %{agent: agent} do
      params = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "message/send",
        "params" => message_params()
      }

      conn =
        Plug.Test.conn(:post, "/", "")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Map.put(:body_params, params)
        |> A2A.Plug.call(plug_opts(agent))

      body = json_body(conn)
      assert body["result"]["kind"] == "task"
      assert body["result"]["status"]["state"] == "completed"
    end

    test "bad JSON returns parse error", %{agent: agent} do
      conn =
        Plug.Test.conn(:post, "/", "not json{{{")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> A2A.Plug.call(plug_opts(agent))

      body = json_body(conn)
      assert body["error"]["code"] == -32_700
    end

    test "missing message returns invalid_params", %{agent: agent} do
      conn =
        json_rpc_conn("message/send", %{})
        |> A2A.Plug.call(plug_opts(agent))

      body = json_body(conn)
      assert body["error"]["code"] == -32_602
    end
  end

  # -- tasks/get ---------------------------------------------------------------

  describe "tasks/get" do
    test "existing task returns task", %{agent: agent} do
      send_conn =
        json_rpc_conn("message/send", message_params())
        |> A2A.Plug.call(plug_opts(agent))

      task_id = json_body(send_conn)["result"]["id"]

      conn =
        json_rpc_conn("tasks/get", %{"id" => task_id})
        |> A2A.Plug.call(plug_opts(agent))

      body = json_body(conn)
      assert body["result"]["id"] == task_id
    end

    test "nonexistent task returns task_not_found", %{agent: agent} do
      conn =
        json_rpc_conn("tasks/get", %{"id" => "nonexistent"})
        |> A2A.Plug.call(plug_opts(agent))

      body = json_body(conn)
      assert body["error"]["code"] == -32_001
    end
  end

  # -- tasks/cancel ------------------------------------------------------------

  describe "tasks/cancel" do
    test "cancels an input_required task" do
      agent = start_supervised!({A2A.Test.MultiTurnAgent, [name: nil]})
      opts = plug_opts(agent)

      # Create a task that pauses at input_required
      send_conn =
        json_rpc_conn("message/send", message_params("order pizza"))
        |> A2A.Plug.call(opts)

      task_id = json_body(send_conn)["result"]["id"]
      assert json_body(send_conn)["result"]["status"]["state"] == "input-required"

      # Cancel it
      conn =
        json_rpc_conn("tasks/cancel", %{"id" => task_id})
        |> A2A.Plug.call(opts)

      body = json_body(conn)
      assert body["result"]["id"] == task_id
      assert body["result"]["status"]["state"] == "canceled"
    end

    test "not found returns error", %{agent: agent} do
      conn =
        json_rpc_conn("tasks/cancel", %{"id" => "nonexistent"})
        |> A2A.Plug.call(plug_opts(agent))

      body = json_body(conn)
      assert body["error"]["code"] == -32_001
    end
  end

  # -- Unknown method ----------------------------------------------------------

  describe "unknown method" do
    test "returns method_not_found", %{agent: agent} do
      conn =
        json_rpc_conn("custom/unknown")
        |> A2A.Plug.call(plug_opts(agent))

      body = json_body(conn)
      assert body["error"]["code"] == -32_601
    end
  end

  # -- Unknown path ------------------------------------------------------------

  describe "unknown path" do
    test "returns 404", %{agent: agent} do
      conn =
        Plug.Test.conn(:get, "/nope")
        |> A2A.Plug.call(plug_opts(agent))

      assert conn.status == 404
    end
  end

  # -- tasks/resubscribe -------------------------------------------------------

  describe "tasks/resubscribe" do
    test "returns unsupported_operation", %{agent: agent} do
      conn =
        json_rpc_conn("tasks/resubscribe", %{"id" => "tsk-1"})
        |> A2A.Plug.call(plug_opts(agent))

      body = json_body(conn)
      assert body["error"]["code"] == -32_004
    end
  end

  defp get_resp_header(conn, key) do
    for {k, v} <- conn.resp_headers, k == key, do: v
  end
end
