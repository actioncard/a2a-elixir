defmodule A2A.ClientExtensionTest do
  use ExUnit.Case, async: true

  alias A2A.Client
  alias A2A.Test.Extensions.{Passport, Timestamp}

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

  describe "new/2 :extensions option" do
    test "stores compiled extensions and sets A2A-Extensions request header" do
      received = self()

      plug = fn conn ->
        send(received, {:headers, conn.req_headers})
        json_resp(conn, 200, jsonrpc_success(%{"task" => @task_json}))
      end

      client =
        Client.new("https://agent.example.com",
          extensions: [Timestamp, {Passport, issuer: "acme"}],
          plug: plug
        )

      assert length(client.extensions) == 2
      assert {:ok, _task} = Client.send_message(client, "hi")

      assert_received {:headers, headers}

      [{"a2a-extensions", value}] =
        Enum.filter(headers, fn {k, _} -> k == "a2a-extensions" end)

      uris = value |> String.split(",") |> Enum.map(&String.trim/1)
      assert "https://example.test/ext/timestamp" in uris
      assert "https://example.test/ext/passport" in uris
    end

    test "does not set the header when no extensions configured" do
      received = self()

      plug = fn conn ->
        send(received, {:headers, conn.req_headers})
        json_resp(conn, 200, jsonrpc_success(%{"task" => @task_json}))
      end

      client = Client.new("https://agent.example.com", plug: plug)
      assert client.extensions == []
      assert {:ok, _task} = Client.send_message(client, "hi")

      assert_received {:headers, headers}
      refute Enum.any?(headers, fn {k, _} -> k == "a2a-extensions" end)
    end
  end

  describe "parse_extensions_header/1 and activated/2" do
    test "parses comma-separated header values" do
      response = %Req.Response{
        headers: %{"a2a-extensions" => ["https://example.test/ext/timestamp"]}
      }

      assert Client.parse_extensions_header(response) ==
               ["https://example.test/ext/timestamp"]
    end

    test "parses multi-value header" do
      response = %Req.Response{
        headers: %{
          "a2a-extensions" => [
            "https://example.test/ext/timestamp, https://example.test/ext/passport"
          ]
        }
      }

      assert Client.parse_extensions_header(response) == [
               "https://example.test/ext/timestamp",
               "https://example.test/ext/passport"
             ]
    end

    test "returns [] when header absent" do
      response = %Req.Response{headers: %{}}
      assert Client.parse_extensions_header(response) == []
    end

    test "activated/2 returns the subset of configured modules echoed by server" do
      client =
        Client.new("https://agent.example.com",
          extensions: [Timestamp, Passport]
        )

      response = %Req.Response{
        headers: %{"a2a-extensions" => ["https://example.test/ext/timestamp"]}
      }

      assert Client.activated(client, response) == [Timestamp]
    end
  end

  describe "round-trip against A2A.Plug" do
    setup do
      agent = start_supervised!({A2A.Test.EchoAgent, [name: nil]})
      {:ok, agent: agent}
    end

    test "client header reaches server, server echoes activated URI", %{agent: agent} do
      plug_opts =
        A2A.Plug.init(
          agent: agent,
          base_url: "http://localhost:4000",
          extensions: [Timestamp]
        )

      plug_fn = fn conn -> A2A.Plug.call(conn, plug_opts) end

      client =
        Client.new("http://localhost:4000",
          extensions: [Timestamp],
          plug: plug_fn
        )

      assert {:ok, task} = Client.send_message(client, "hi")

      # The Timestamp extension's handle_response wrote into task metadata
      assert task.metadata["https://example.test/ext/timestamp"] ==
               %{"finished_at" => 1_700_000_000_000}
    end

    test "required server extension missing on client triggers -32008", %{agent: agent} do
      plug_opts =
        A2A.Plug.init(
          agent: agent,
          base_url: "http://localhost:4000",
          extensions: [Passport]
        )

      plug_fn = fn conn -> A2A.Plug.call(conn, plug_opts) end
      client = Client.new("http://localhost:4000", plug: plug_fn)

      assert {:error, %A2A.JSONRPC.Error{code: -32_008}} =
               Client.send_message(client, "hi")
    end
  end
end
