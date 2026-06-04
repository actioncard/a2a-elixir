defmodule A2A.ClientVersionTest do
  use ExUnit.Case, async: true

  alias A2A.Client

  @task_json %{
    "kind" => "task",
    "id" => "tsk-1",
    "status" => %{"state" => "TASK_STATE_COMPLETED"},
    "history" => [
      %{"messageId" => "m1", "role" => "ROLE_USER", "parts" => [%{"text" => "hi"}]},
      %{"messageId" => "m2", "role" => "ROLE_AGENT", "parts" => [%{"text" => "ok"}]}
    ],
    "artifacts" => [%{"parts" => [%{"text" => "ok"}]}]
  }

  defp jsonrpc_success(result, id \\ 1) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp json_resp(conn, status, body, headers \\ []) do
    conn =
      Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  describe "new/2 :version option" do
    test "sends A2A-Version: 1.0 by default" do
      received = self()

      plug = fn conn ->
        send(received, {:headers, conn.req_headers})
        json_resp(conn, 200, jsonrpc_success(%{"task" => @task_json}))
      end

      client = Client.new("https://agent.example.com", plug: plug)
      assert {:ok, _task} = Client.send_message(client, "hi")

      assert_received {:headers, headers}
      assert {"a2a-version", "1.0"} in headers
    end

    test "honors an explicit :version" do
      received = self()

      plug = fn conn ->
        send(received, {:headers, conn.req_headers})
        json_resp(conn, 200, jsonrpc_success(%{"task" => @task_json}))
      end

      client = Client.new("https://agent.example.com", version: "0.3", plug: plug)
      assert {:ok, _task} = Client.send_message(client, "hi")

      assert_received {:headers, headers}
      assert {"a2a-version", "0.3"} in headers
    end
  end

  describe "version/1 response helper" do
    test "reads the server's negotiated version" do
      response = %Req.Response{headers: %{"a2a-version" => ["1.0"]}}
      assert Client.version(response) == "1.0"
    end

    test "returns nil when header is absent" do
      response = %Req.Response{headers: %{}}
      assert Client.version(response) == nil
    end

    test "accepts a bare string header value" do
      response = %Req.Response{headers: %{"a2a-version" => "0.3"}}
      assert Client.version(response) == "0.3"
    end
  end
end
