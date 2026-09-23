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

  defp owner_authorizer do
    fn _operation, task, %{metadata: metadata} ->
      metadata["user_id"] == task.metadata["owner_id"]
    end
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
      refute Map.has_key?(body, "url")

      assert [%{"url" => "http://localhost:4000"} | _] =
               body["supportedInterfaces"]

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

  # -- Agent card caching headers ----------------------------------------------

  describe "agent card caching headers" do
    defp card_conn(opts, base_url \\ nil) do
      conn = Plug.Test.conn(:get, "/.well-known/agent-card.json")
      conn = if base_url, do: A2A.Plug.put_base_url(conn, base_url), else: conn
      A2A.Plug.call(conn, opts)
    end

    test "ETag is a quoted sha256 and is stable across identical requests", %{agent: agent} do
      opts = plug_opts(agent)

      etag = card_conn(opts) |> get_resp_header("etag") |> hd()

      assert etag =~ ~r/^"[0-9a-f]{64}"$/
      assert etag == card_conn(opts) |> get_resp_header("etag") |> hd()
    end

    test "ETag tracks the body when base_url is overridden per request", %{agent: agent} do
      opts = plug_opts(agent)

      default = card_conn(opts) |> get_resp_header("etag") |> hd()
      overridden = card_conn(opts, "https://other.example") |> get_resp_header("etag") |> hd()

      refute default == overridden
    end

    test "Last-Modified renders the configured time as an IMF-fixdate", %{agent: agent} do
      opts = plug_opts(agent, last_modified: ~U[2026-03-06 09:05:01Z])

      assert card_conn(opts) |> get_resp_header("last-modified") |> hd() ==
               "Fri, 06 Mar 2026 09:05:01 GMT"
    end

    test "Last-Modified normalizes a non-UTC DateTime", %{agent: agent} do
      # +02:00 at 11:05:01 is the same instant as 09:05:01 UTC.
      shifted = %DateTime{
        ~U[2026-03-06 09:05:01Z]
        | utc_offset: 7200,
          std_offset: 0,
          zone_abbr: "CEST",
          time_zone: "Europe/Stockholm",
          hour: 11
      }

      opts = plug_opts(agent, last_modified: shifted)

      assert card_conn(opts) |> get_resp_header("last-modified") |> hd() ==
               "Fri, 06 Mar 2026 09:05:01 GMT"
    end

    test "Cache-Control replaces the Plug default with a public max-age", %{agent: agent} do
      # Plug.Conn defaults every response to "max-age=0, private,
      # must-revalidate", so asserting mere presence here would be vacuous.
      assert card_conn(plug_opts(agent)) |> get_resp_header("cache-control") |> hd() ==
               "public, max-age=300"
    end
  end

  # -- History length ----------------------------------------------------------

  describe "historyLength" do
    defp completed_task_id(agent) do
      json_rpc_conn("message/send", message_params())
      |> A2A.Plug.call(plug_opts(agent))
      |> json_body()
      |> get_in(["result", "task", "id"])
    end

    test "tasks/get truncates history", %{agent: agent} do
      task_id = completed_task_id(agent)

      full =
        json_rpc_conn("tasks/get", %{"id" => task_id})
        |> A2A.Plug.call(plug_opts(agent))
        |> json_body()

      assert length(full["result"]["history"]) > 1
    end

    test "tasks/get accepts historyLength in either spelling", %{agent: agent} do
      # Spec and our own client send camelCase; some JSON-RPC clients send the
      # protobuf field name instead, so both must truncate.
      for key <- ["historyLength", "history_length"] do
        task_id = completed_task_id(agent)

        body =
          json_rpc_conn("tasks/get", %{"id" => task_id, key => 0})
          |> A2A.Plug.call(plug_opts(agent))
          |> json_body()

        assert body["result"]["history"] in [nil, []], "#{key} did not truncate"
      end
    end

    test "message/send honours configuration.historyLength", %{agent: agent} do
      params = Map.put(message_params(), "configuration", %{"historyLength" => 0})

      body =
        json_rpc_conn("message/send", params)
        |> A2A.Plug.call(plug_opts(agent))
        |> json_body()

      assert body["result"]["task"]["history"] in [nil, []]
    end

    test "message/send keeps history when no configuration is sent", %{agent: agent} do
      body =
        json_rpc_conn("message/send", message_params())
        |> A2A.Plug.call(plug_opts(agent))
        |> json_body()

      assert length(body["result"]["task"]["history"]) > 0
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
      assert is_binary(json_body(conn)["result"]["task"]["id"])
    end
  end

  # -- message/send with a bare-message agent ---------------------------------

  describe "message/send with a bare-message agent" do
    setup do
      {:ok, message_agent: start_supervised!({A2A.Test.MessageAgent, [name: nil]})}
    end

    test "returns result.message instead of result.task", %{message_agent: agent} do
      conn =
        json_rpc_conn("message/send", message_params("hi"))
        |> A2A.Plug.call(plug_opts(agent))

      assert conn.status == 200

      result = json_body(conn)["result"]
      refute Map.has_key?(result, "task")
      assert result["message"]["role"] == "ROLE_AGENT"
      assert [%{"text" => "Direct: hi"}] = result["message"]["parts"]
      assert is_binary(result["message"]["messageId"])
    end

    test "echoes the request contextId on the message", %{message_agent: agent} do
      params = Map.put(message_params("hi"), "contextId", "ctx-42")

      conn =
        json_rpc_conn("message/send", params)
        |> A2A.Plug.call(plug_opts(agent))

      assert json_body(conn)["result"]["message"]["contextId"] == "ctx-42"
    end

    test "a bare message on a task-scoped request returns -32006", %{message_agent: agent} do
      conn =
        json_rpc_conn("message/send", message_params("start"))
        |> A2A.Plug.call(plug_opts(agent))

      task_id = json_body(conn)["result"]["task"]["id"]
      assert is_binary(task_id)

      conn =
        json_rpc_conn("message/send", Map.put(message_params("more"), "id", task_id))
        |> A2A.Plug.call(plug_opts(agent))

      assert json_body(conn)["error"]["code"] == -32_006
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
      assert is_binary(body["result"]["task"]["id"])
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
      assert is_binary(body["result"]["task"]["id"])
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

    test "unknown taskId returns task_not_found", %{agent: agent} do
      params = put_in(message_params()["message"]["taskId"], "nonexistent")

      conn =
        json_rpc_conn("message/send", params)
        |> A2A.Plug.call(plug_opts(agent))

      body = json_body(conn)
      assert body["error"]["code"] == -32_001
      assert body["error"]["message"] == "Task not found"

      # No internal reason leaks, but the spec-required ErrorInfo is present.
      assert [info] = body["error"]["data"]
      assert info["reason"] == "TASK_NOT_FOUND"
      refute Map.has_key?(info, "metadata")
    end

    test "terminal task returns unsupported_operation", %{agent: agent} do
      first =
        json_rpc_conn("message/send", message_params())
        |> A2A.Plug.call(plug_opts(agent))
        |> json_body()

      # EchoAgent completes immediately, so the task is terminal by now.
      assert first["result"]["task"]["status"]["state"] == "TASK_STATE_COMPLETED"
      task_id = first["result"]["task"]["id"]

      params = put_in(message_params()["message"]["taskId"], task_id)

      conn =
        json_rpc_conn("message/send", params)
        |> A2A.Plug.call(plug_opts(agent))

      body = json_body(conn)
      assert body["error"]["code"] == -32_004
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

    test "authorize_task denies access without leaking task existence", %{agent: agent} do
      opts = plug_opts(agent, authorize_task: owner_authorizer())

      send_conn =
        json_rpc_conn(
          "message/send",
          Map.put(message_params(), "metadata", %{"owner_id" => "u-1"})
        )
        |> A2A.Plug.call(opts)

      task_id = json_body(send_conn)["result"]["task"]["id"]

      conn =
        json_rpc_conn("tasks/get", %{"id" => task_id})
        |> A2A.Plug.put_metadata(%{"user_id" => "u-2"})
        |> A2A.Plug.call(opts)

      body = json_body(conn)
      assert body["error"]["code"] == -32_001
      assert body["error"]["message"] == "Task not found"
    end

    test "authorize_task allows matching task owner", %{agent: agent} do
      opts = plug_opts(agent, authorize_task: owner_authorizer())

      send_conn =
        json_rpc_conn(
          "message/send",
          Map.put(message_params(), "metadata", %{"owner_id" => "u-1"})
        )
        |> A2A.Plug.call(opts)

      task_id = json_body(send_conn)["result"]["task"]["id"]

      conn =
        json_rpc_conn("tasks/get", %{"id" => task_id})
        |> A2A.Plug.put_metadata(%{"user_id" => "u-1"})
        |> A2A.Plug.call(opts)

      body = json_body(conn)
      assert body["result"]["id"] == task_id
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

    test "authorize_task denies cancel before mutating task" do
      agent = start_supervised!({A2A.Test.MultiTurnAgent, [name: nil]})
      opts = plug_opts(agent, authorize_task: owner_authorizer())

      send_conn =
        json_rpc_conn(
          "message/send",
          message_params("order pizza") |> Map.put("metadata", %{"owner_id" => "u-1"})
        )
        |> A2A.Plug.call(opts)

      task_id = json_body(send_conn)["result"]["task"]["id"]

      denied_conn =
        json_rpc_conn("tasks/cancel", %{"id" => task_id})
        |> A2A.Plug.put_metadata(%{"user_id" => "u-2"})
        |> A2A.Plug.call(opts)

      assert json_body(denied_conn)["error"]["code"] == -32_001

      get_conn =
        json_rpc_conn("tasks/get", %{"id" => task_id})
        |> A2A.Plug.put_metadata(%{"user_id" => "u-1"})
        |> A2A.Plug.call(opts)

      assert json_body(get_conn)["result"]["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
    end
  end

  # -- tasks/list --------------------------------------------------------------

  describe "tasks/list" do
    test "authorize_task filters tasks from list results", %{agent: agent} do
      opts = plug_opts(agent, authorize_task: owner_authorizer())

      task_ids =
        for owner_id <- ["u-1", "u-2"] do
          conn =
            json_rpc_conn(
              "message/send",
              message_params("hello #{owner_id}")
              |> Map.put("metadata", %{"owner_id" => owner_id})
            )
            |> A2A.Plug.call(opts)

          json_body(conn)["result"]["task"]["id"]
        end

      conn =
        json_rpc_conn("tasks/list", %{})
        |> A2A.Plug.put_metadata(%{"user_id" => "u-1"})
        |> A2A.Plug.call(opts)

      body = json_body(conn)

      assert Enum.map(body["result"]["tasks"], & &1["id"]) == [List.first(task_ids)]
      assert body["result"]["totalSize"] == 1
      assert body["result"]["pageSize"] == 1
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
      refute Map.has_key?(json_body(conn), "url")

      assert [%{"url" => "https://tenant.example.com/a2a"} | _] =
               json_body(conn)["supportedInterfaces"]
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
      assert is_binary(json_body(conn)["result"]["task"]["id"])
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
      assert is_binary(json_body(conn)["result"]["task"]["id"])
    end
  end

  # -- tasks/pushNotificationConfig --------------------------------------------

  describe "push notification configs" do
    test "every method is unsupported when the capability is not declared", %{agent: agent} do
      opts = plug_opts(agent)

      methods = [
        {"set", %{"task_id" => "tsk-1", "url" => "https://example.com/hook"}},
        {"get", %{"task_id" => "tsk-1", "id" => "pcfg-1"}},
        {"list", %{"task_id" => "tsk-1"}},
        {"delete", %{"task_id" => "tsk-1", "id" => "pcfg-1"}}
      ]

      for {method, params} <- methods do
        conn =
          json_rpc_conn("tasks/pushNotificationConfig/#{method}", params)
          |> A2A.Plug.call(opts)

        assert json_body(conn)["error"]["code"] == -32_003, "#{method} was not gated"
      end
    end

    # The gate lives in the handler callback, which params are decoded before
    # reaching. A malformed body is therefore reported as malformed rather than
    # as unsupported — the well-formed case above is what the spec pins down.
    test "a malformed set is invalid params, not unsupported", %{agent: agent} do
      conn =
        json_rpc_conn("tasks/pushNotificationConfig/set", %{"task_id" => "tsk-1"})
        |> A2A.Plug.call(plug_opts(agent))

      assert json_body(conn)["error"]["code"] == -32_602
    end

    test "set, get, list and delete round-trip once declared", %{agent: agent} do
      opts = push_opts(agent)
      task_id = create_task(opts)

      set_body =
        json_rpc_conn("CreateTaskPushNotificationConfig", %{
          "task_id" => task_id,
          "id" => "pcfg-1",
          "url" => "https://example.com/hook",
          "authentication" => %{"scheme" => "Bearer", "credentials" => "s3cret"}
        })
        |> A2A.Plug.call(opts)
        |> json_body()

      assert set_body["result"]["id"] == "pcfg-1"
      assert set_body["result"]["taskId"] == task_id

      get_body =
        json_rpc_conn("GetTaskPushNotificationConfig", %{"task_id" => task_id, "id" => "pcfg-1"})
        |> A2A.Plug.call(opts)
        |> json_body()

      assert get_body["result"]["url"] == "https://example.com/hook"
      assert get_body["result"]["authentication"]["credentials"] == "s3cret"

      list_body =
        json_rpc_conn("ListTaskPushNotificationConfigs", %{"task_id" => task_id})
        |> A2A.Plug.call(opts)
        |> json_body()

      assert [%{"id" => "pcfg-1"}] = list_body["result"]["configs"]

      delete_body =
        json_rpc_conn("DeleteTaskPushNotificationConfig", %{
          "task_id" => task_id,
          "id" => "pcfg-1"
        })
        |> A2A.Plug.call(opts)
        |> json_body()

      assert delete_body["result"] == %{}

      gone_body =
        json_rpc_conn("GetTaskPushNotificationConfig", %{"task_id" => task_id, "id" => "pcfg-1"})
        |> A2A.Plug.call(opts)
        |> json_body()

      assert gone_body["error"]["code"] == -32_001
    end

    test "deleting a config twice stays successful", %{agent: agent} do
      opts = push_opts(agent)
      task_id = create_task(opts)
      params = %{"task_id" => task_id, "id" => "pcfg-missing"}

      for _ <- 1..2 do
        body =
          json_rpc_conn("DeleteTaskPushNotificationConfig", params)
          |> A2A.Plug.call(opts)
          |> json_body()

        assert body["result"] == %{}
        refute Map.has_key?(body, "error")
      end
    end

    test "the server assigns a config id when the client omits one", %{agent: agent} do
      opts = push_opts(agent)
      task_id = create_task(opts)

      body =
        json_rpc_conn("CreateTaskPushNotificationConfig", %{
          "task_id" => task_id,
          "url" => "https://example.com/hook"
        })
        |> A2A.Plug.call(opts)
        |> json_body()

      assert "pcfg-" <> _ = body["result"]["id"]
    end

    test "a config for a task that does not exist is rejected", %{agent: agent} do
      opts = push_opts(agent)

      body =
        json_rpc_conn("CreateTaskPushNotificationConfig", %{
          "task_id" => "tsk-nonexistent",
          "url" => "https://example.com/hook"
        })
        |> A2A.Plug.call(opts)
        |> json_body()

      assert body["error"]["code"] == -32_001
    end

    test "configs are scoped to their task", %{agent: agent} do
      opts = push_opts(agent)
      task_id = create_task(opts)
      other_task_id = create_task(opts)

      json_rpc_conn("CreateTaskPushNotificationConfig", %{
        "task_id" => task_id,
        "id" => "pcfg-1",
        "url" => "https://example.com/hook"
      })
      |> A2A.Plug.call(opts)

      body =
        json_rpc_conn("ListTaskPushNotificationConfigs", %{"task_id" => other_task_id})
        |> A2A.Plug.call(opts)
        |> json_body()

      assert body["result"]["configs"] == []
    end

    test "authorize_task denies a push read without leaking the task", %{agent: agent} do
      opts = push_opts(agent, authorize_task: owner_authorizer())
      task_id = create_task(opts, %{"owner_id" => "u-1"})

      body =
        json_rpc_conn("GetTaskPushNotificationConfig", %{"task_id" => task_id, "id" => "pcfg-1"})
        |> A2A.Plug.put_metadata(%{"user_id" => "u-2"})
        |> A2A.Plug.call(opts)
        |> json_body()

      assert body["error"]["code"] == -32_001
      assert body["error"]["message"] == "Task not found"
    end

    test "each push method authorizes under its own operation atom", %{agent: agent} do
      opts = push_opts(agent, authorize_task: recording_authorizer(self()))
      task_id = create_task(opts)
      flush_authorizations()

      methods = [
        {"CreateTaskPushNotificationConfig", :push_set},
        {"GetTaskPushNotificationConfig", :push_get},
        {"ListTaskPushNotificationConfigs", :push_list},
        {"DeleteTaskPushNotificationConfig", :push_delete}
      ]

      for {method, operation} <- methods do
        params = %{
          "task_id" => task_id,
          "id" => "pcfg-1",
          "url" => "https://example.com/hook"
        }

        json_rpc_conn(method, params) |> A2A.Plug.call(opts)

        assert_receive {:authorized, ^operation}
      end
    end
  end

  describe "inline push config on message/send" do
    test "registers a config sent as configuration.taskPushNotificationConfig", %{agent: agent} do
      opts = push_opts(agent)

      params =
        Map.put(message_params(), "configuration", %{
          "taskPushNotificationConfig" => %{
            "url" => "https://example.com/hook",
            "authentication" => %{"scheme" => "Bearer", "credentials" => "tok"}
          }
        })

      task_id =
        json_rpc_conn("message/send", params)
        |> A2A.Plug.call(opts)
        |> json_body()
        |> get_in(["result", "task", "id"])

      listed =
        json_rpc_conn("tasks/pushNotificationConfig/list", %{"taskId" => task_id})
        |> A2A.Plug.call(opts)
        |> json_body()
        |> get_in(["result", "configs"])

      assert [config] = listed
      assert config["url"] == "https://example.com/hook"
      assert config["taskId"] == task_id
      # The server assigns an id when the client does not supply one.
      assert String.starts_with?(config["id"], "pcfg-")
    end

    test "ignores an inline config when the capability is undeclared", %{agent: agent} do
      opts = plug_opts(agent)

      params =
        Map.put(message_params(), "configuration", %{
          "taskPushNotificationConfig" => %{"url" => "https://example.com/hook"}
        })

      body =
        json_rpc_conn("message/send", params)
        |> A2A.Plug.call(opts)
        |> json_body()

      # The send still succeeds — an undeclared capability makes the extra
      # field inert rather than turning a valid request into an error.
      assert get_in(body, ["result", "task", "id"])
      refute body["error"]
    end

    test "does not register when the authorizer denies :push_set", %{agent: agent} do
      opts = push_opts(agent, authorize_task: fn op, _task, _ctx -> op != :push_set end)

      params =
        Map.put(message_params(), "configuration", %{
          "taskPushNotificationConfig" => %{"url" => "https://example.com/hook"}
        })

      task_id =
        json_rpc_conn("message/send", params)
        |> A2A.Plug.call(opts)
        |> json_body()
        |> get_in(["result", "task", "id"])

      listed =
        json_rpc_conn("tasks/pushNotificationConfig/list", %{"taskId" => task_id})
        |> A2A.Plug.call(opts)
        |> json_body()
        |> get_in(["result", "configs"])

      # The inline path must not be a way around the hook the CRUD method runs.
      assert listed == []
    end

    test "leaves a send with no configuration untouched", %{agent: agent} do
      opts = push_opts(agent)
      task_id = create_task(opts)

      listed =
        json_rpc_conn("tasks/pushNotificationConfig/list", %{"taskId" => task_id})
        |> A2A.Plug.call(opts)
        |> json_body()
        |> get_in(["result", "configs"])

      assert listed == []
    end
  end

  defp push_opts(agent, extra \\ []) do
    plug_opts(agent, [agent_card_opts: [capabilities: %{push_notifications: true}]] ++ extra)
  end

  defp create_task(opts, metadata \\ %{}) do
    json_rpc_conn("message/send", Map.put(message_params(), "metadata", metadata))
    |> A2A.Plug.call(opts)
    |> json_body()
    |> get_in(["result", "task", "id"])
  end

  defp recording_authorizer(pid) do
    fn operation, _task, _context ->
      send(pid, {:authorized, operation})
      true
    end
  end

  defp flush_authorizations do
    receive do
      {:authorized, _} -> flush_authorizations()
    after
      0 -> :ok
    end
  end

  defp get_resp_header(conn, key) do
    for {k, v} <- conn.resp_headers, k == key, do: v
  end
end
