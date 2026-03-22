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
        "messageId" => "msg-test",
        "role" => "user",
        "parts" => [%{"kind" => "text", "text" => text}]
      }
    }
  end

  defp json_body(conn) do
    Jason.decode!(conn.resp_body)
  end

  setup do
    agent = start_supervised!({A2A.Test.EchoAgent, [name: nil]})
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
      assert json_body(conn)["result"]["task"]["kind"] == "task"
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
      assert body["result"]["task"]["kind"] == "task"
      assert body["result"]["task"]["status"]["state"] == "TASK_STATE_COMPLETED"
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
      assert body["result"]["task"]["kind"] == "task"
      assert body["result"]["task"]["status"]["state"] == "TASK_STATE_COMPLETED"
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

      task_id = json_body(send_conn)["result"]["task"]["id"]

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

      task_id = json_body(send_conn)["result"]["task"]["id"]

      assert json_body(send_conn)["result"]["task"]["status"]["state"] ==
               "TASK_STATE_INPUT_REQUIRED"

      # Cancel it
      conn =
        json_rpc_conn("tasks/cancel", %{"id" => task_id})
        |> A2A.Plug.call(opts)

      body = json_body(conn)
      assert body["result"]["id"] == task_id
      assert body["result"]["status"]["state"] == "TASK_STATE_CANCELED"
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

  # -- put_base_url/2 overrides ------------------------------------------------

  describe "put_base_url/2" do
    test "overrides init base_url in agent card", %{agent: agent} do
      conn =
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> A2A.Plug.put_base_url("https://tenant.example.com/a2a")
        |> A2A.Plug.call(plug_opts(agent))

      assert conn.status == 200
      assert json_body(conn)["url"] == "https://tenant.example.com/a2a"
    end

    test "get_base_url/1 returns stored value" do
      conn =
        Plug.Test.conn(:get, "/")
        |> A2A.Plug.put_base_url("https://example.com")

      assert A2A.Plug.get_base_url(conn) == "https://example.com"
    end

    test "get_base_url/1 returns nil when not set" do
      conn = Plug.Test.conn(:get, "/")
      assert A2A.Plug.get_base_url(conn) == nil
    end
  end

  # -- put_metadata/2 overrides -----------------------------------------------

  describe "put_metadata/2" do
    test "init metadata flows to task", %{agent: agent} do
      opts =
        A2A.Plug.init(
          agent: agent,
          base_url: "http://localhost:4000",
          metadata: %{"env" => "prod"}
        )

      conn =
        json_rpc_conn("message/send", message_params())
        |> A2A.Plug.call(opts)

      body = json_body(conn)
      assert body["result"]["task"]["metadata"]["env"] == "prod"
    end

    test "conn metadata overrides init metadata", %{agent: agent} do
      opts =
        A2A.Plug.init(
          agent: agent,
          base_url: "http://localhost:4000",
          metadata: %{"env" => "prod", "region" => "us"}
        )

      conn =
        json_rpc_conn("message/send", message_params())
        |> A2A.Plug.put_metadata(%{"env" => "staging", "tenant_id" => "t-1"})
        |> A2A.Plug.call(opts)

      body = json_body(conn)
      meta = body["result"]["task"]["metadata"]
      assert meta["env"] == "staging"
      assert meta["region"] == "us"
      assert meta["tenant_id"] == "t-1"
    end

    test "request metadata overrides conn metadata", %{agent: agent} do
      opts =
        A2A.Plug.init(
          agent: agent,
          base_url: "http://localhost:4000",
          metadata: %{"env" => "prod"}
        )

      params =
        message_params()
        |> Map.put("metadata", %{"env" => "test", "request_key" => "val"})

      conn =
        json_rpc_conn("message/send", params)
        |> A2A.Plug.put_metadata(%{"tenant_id" => "t-1"})
        |> A2A.Plug.call(opts)

      body = json_body(conn)
      meta = body["result"]["task"]["metadata"]
      # 3-layer merge: init("prod") → conn("t-1") → request("test")
      assert meta["env"] == "test"
      assert meta["tenant_id"] == "t-1"
      assert meta["request_key"] == "val"
    end

    test "get_metadata/1 returns stored value" do
      conn =
        Plug.Test.conn(:get, "/")
        |> A2A.Plug.put_metadata(%{"key" => "val"})

      assert A2A.Plug.get_metadata(conn) == %{"key" => "val"}
    end

    test "get_metadata/1 returns nil when not set" do
      conn = Plug.Test.conn(:get, "/")
      assert A2A.Plug.get_metadata(conn) == nil
    end
  end

  # -- agent_card_path: false --------------------------------------------------

  describe "agent_card_path: false" do
    test "GET to default agent card path returns 404", %{agent: agent} do
      opts = plug_opts(agent, agent_card_path: false)

      conn =
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> A2A.Plug.call(opts)

      assert conn.status == 404
    end

    test "JSON-RPC still works", %{agent: agent} do
      opts = plug_opts(agent, agent_card_path: false)

      conn =
        json_rpc_conn("message/send", message_params())
        |> A2A.Plug.call(opts)

      assert conn.status == 200
      assert json_body(conn)["result"]["task"]["kind"] == "task"
    end
  end

  # -- Missing base_url --------------------------------------------------------

  describe "missing base_url" do
    test "raises ArgumentError on agent card GET", %{agent: agent} do
      opts = A2A.Plug.init(agent: agent)

      assert_raise ArgumentError, ~r/base_url/, fn ->
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> A2A.Plug.call(opts)
      end
    end

    test "JSON-RPC works without base_url", %{agent: agent} do
      opts = A2A.Plug.init(agent: agent)

      conn =
        json_rpc_conn("message/send", message_params())
        |> A2A.Plug.call(opts)

      assert conn.status == 200
      assert json_body(conn)["result"]["task"]["kind"] == "task"
    end
  end

  defp get_resp_header(conn, key) do
    for {k, v} <- conn.resp_headers, k == key, do: v
  end
end
