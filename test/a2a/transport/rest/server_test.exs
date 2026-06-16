defmodule A2A.Transport.REST.ServerTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias A2A.Transport.REST.Server

  defp server_opts(agent, extra \\ []) do
    Server.init([agent: agent, base_url: "http://localhost:8080"] ++ extra)
  end

  defp message_json(text \\ "hello") do
    %{
      "messageId" => "msg-test",
      "role" => "user",
      "parts" => [%{"kind" => "text", "text" => text}]
    }
  end

  defp post_json(path, body) do
    :post
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
  end

  defp json_body(c), do: Jason.decode!(c.resp_body)

  defp owner_authorizer do
    fn _operation, task, %{metadata: metadata} ->
      metadata["user_id"] == task.metadata["owner_id"]
    end
  end

  setup do
    agent = start_supervised!({A2A.Test.EchoAgent, [name: nil]})
    {:ok, agent: agent}
  end

  # -- POST /v1/message/send -------------------------------------------------

  describe "POST /v1/message/send" do
    test "returns completed task", %{agent: agent} do
      opts = server_opts(agent)

      conn =
        post_json("/v1/message/send", %{"message" => message_json("hi")})
        |> Server.call(opts)

      assert conn.status == 200
      body = json_body(conn)
      assert is_binary(body["task"]["id"])
      assert body["task"]["status"]["state"] == "TASK_STATE_COMPLETED"
    end

    test "missing message returns 400", %{agent: agent} do
      opts = server_opts(agent)

      conn =
        post_json("/v1/message/send", %{"oops" => "x"})
        |> Server.call(opts)

      assert conn.status == 400
    end

    test "invalid JSON returns 400", %{agent: agent} do
      opts = server_opts(agent)

      conn =
        :post
        |> conn("/v1/message/send", "bad{")
        |> put_req_header("content-type", "application/json")
        |> Server.call(opts)

      assert conn.status == 400
    end

    test "metadata flows to task", %{agent: agent} do
      opts = server_opts(agent, metadata: %{"env" => "test"})

      conn =
        post_json("/v1/message/send", %{"message" => message_json()})
        |> Server.call(opts)

      assert json_body(conn)["task"]["metadata"]["env"] == "test"
    end
  end

  # -- GET /v1/tasks/:id -----------------------------------------------------

  describe "GET /v1/tasks/:id" do
    test "returns existing task", %{agent: agent} do
      opts = server_opts(agent)

      send_conn =
        post_json("/v1/message/send", %{"message" => message_json()})
        |> Server.call(opts)

      task_id = json_body(send_conn)["task"]["id"]

      conn =
        :get
        |> conn("/v1/tasks/#{task_id}")
        |> Server.call(opts)

      assert conn.status == 200
      body = json_body(conn)
      assert body["id"] == task_id
      assert body["status"]["state"] == "TASK_STATE_COMPLETED"
    end

    test "returns 404 for nonexistent task", %{agent: agent} do
      opts = server_opts(agent)

      conn =
        :get
        |> conn("/v1/tasks/nonexistent")
        |> Server.call(opts)

      assert conn.status == 404
    end

    test "authorize_task denies access", %{agent: agent} do
      opts = server_opts(agent, authorize_task: owner_authorizer())

      send_conn =
        post_json("/v1/message/send", %{
          "message" => message_json(),
          "metadata" => %{"owner_id" => "u-1"}
        })
        |> Server.call(opts)

      task_id = json_body(send_conn)["task"]["id"]

      # No user_id in metadata -> authorizer denies -> 404
      conn =
        :get
        |> conn("/v1/tasks/#{task_id}")
        |> Server.call(opts)

      assert conn.status == 404
    end
  end

  # -- POST /v1/tasks/:id/cancel ---------------------------------------------

  describe "POST /v1/tasks/:id/cancel" do
    test "cancels an input_required task" do
      agent = start_supervised!({A2A.Test.MultiTurnAgent, [name: nil]})
      opts = server_opts(agent)

      send_conn =
        post_json("/v1/message/send", %{"message" => message_json("order pizza")})
        |> Server.call(opts)

      body = json_body(send_conn)
      task_id = body["task"]["id"]
      assert body["task"]["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"

      conn =
        post_json("/v1/tasks/#{task_id}/cancel", %{})
        |> Server.call(opts)

      assert conn.status == 200
      cancel_body = json_body(conn)
      # tasks/cancel returns the task directly (not wrapped in "task")
      assert cancel_body["status"]["state"] == "TASK_STATE_CANCELED"
    end

    test "returns 404 for nonexistent task", %{agent: agent} do
      opts = server_opts(agent)

      conn =
        post_json("/v1/tasks/nonexistent/cancel", %{})
        |> Server.call(opts)

      assert conn.status == 404
    end
  end

  # -- GET /v1/tasks ---------------------------------------------------------

  describe "GET /v1/tasks" do
    test "lists all tasks", %{agent: agent} do
      opts = server_opts(agent)

      for text <- ["one", "two"] do
        post_json("/v1/message/send", %{"message" => message_json(text)})
        |> Server.call(opts)
      end

      conn =
        :get
        |> conn("/v1/tasks")
        |> Server.call(opts)

      assert conn.status == 200
      body = json_body(conn)
      assert is_list(body["tasks"])
      assert length(body["tasks"]) == 2
    end

    test "authorize_task filters list", %{agent: agent} do
      opts = server_opts(agent, authorize_task: owner_authorizer())

      for owner <- ["u-1", "u-2"] do
        post_json("/v1/message/send", %{
          "message" => message_json("hi #{owner}"),
          "metadata" => %{"owner_id" => owner}
        })
        |> Server.call(opts)
      end

      # No user_id -> all denied
      conn =
        :get
        |> conn("/v1/tasks")
        |> Server.call(opts)

      assert conn.status == 200
      assert json_body(conn)["tasks"] == []
    end
  end

  # -- GET /v1/card ----------------------------------------------------------

  describe "GET /v1/card" do
    test "returns agent card", %{agent: agent} do
      opts = server_opts(agent)

      conn =
        :get
        |> conn("/v1/card")
        |> Server.call(opts)

      assert conn.status == 200
      assert json_body(conn)["name"] == "echo"
    end

    test "returns error without base_url", %{agent: agent} do
      opts = Server.init(agent: agent)

      conn =
        :get
        |> conn("/v1/card")
        |> Server.call(opts)

      assert conn.status == 500
    end
  end

  # -- Unknown routes --------------------------------------------------------

  describe "unknown routes" do
    test "returns 404", %{agent: agent} do
      opts = server_opts(agent)

      conn =
        :get
        |> conn("/v1/unknown")
        |> Server.call(opts)

      assert conn.status == 404
    end
  end

  # -- Error sanitization ----------------------------------------------------

  describe "error sanitization" do
    test "no inspect() leaks in errors", %{agent: agent} do
      opts = server_opts(agent)

      conn =
        :get
        |> conn("/v1/tasks/nonexistent")
        |> Server.call(opts)

      refute conn.resp_body =~ "%{"
      refute conn.resp_body =~ ":not_found"
    end
  end
end
