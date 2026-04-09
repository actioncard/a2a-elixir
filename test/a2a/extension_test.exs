defmodule A2A.ExtensionTest do
  use ExUnit.Case, async: true

  @moduletag :plug

  alias A2A.AgentExtension

  # -- Helpers ----------------------------------------------------------------

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

  defp get_resp_header(conn, key) do
    for {k, v} <- conn.resp_headers, k == key, do: v
  end

  setup do
    agent = start_supervised!(A2A.Test.EchoAgent)
    {:ok, agent: agent}
  end

  # -- AgentExtension struct ---------------------------------------------------

  describe "AgentExtension struct" do
    test "creates with required fields" do
      ext = %AgentExtension{uri: "https://example.com/ext/a"}
      assert ext.uri == "https://example.com/ext/a"
      assert ext.required == false
      assert ext.description == nil
      assert ext.params == nil
    end

    test "creates with all fields" do
      ext = %AgentExtension{
        uri: "https://example.com/ext/b",
        description: "Test extension",
        required: true,
        params: %{"version" => "1.0"}
      }

      assert ext.uri == "https://example.com/ext/b"
      assert ext.description == "Test extension"
      assert ext.required == true
      assert ext.params == %{"version" => "1.0"}
    end

    test "enforces :uri key" do
      assert_raise ArgumentError, fn ->
        struct!(AgentExtension, %{description: "no URI"})
      end
    end
  end

  # -- Extension negotiation: no extensions configured -------------------------

  describe "no extensions configured" do
    test "requests succeed without A2A-Extensions header", %{agent: agent} do
      conn =
        json_rpc_conn("message/send", message_params())
        |> A2A.Plug.call(plug_opts(agent))

      assert conn.status == 200
      body = json_body(conn)
      assert body["result"]["task"]["kind"] == "task"

      # No A2A-Extensions response header when no extensions configured
      assert get_resp_header(conn, "a2a-extensions") == []
    end
  end

  # -- Extension negotiation: optional extensions only -------------------------

  describe "optional extensions only" do
    setup %{agent: agent} do
      extensions = [
        %AgentExtension{uri: "https://example.com/ext/timestamp", description: "Timestamps"},
        %AgentExtension{uri: "https://example.com/ext/tracing", required: false}
      ]

      opts = plug_opts(agent, extensions: extensions)
      {:ok, opts: opts}
    end

    test "requests succeed without A2A-Extensions header", %{opts: opts} do
      conn =
        json_rpc_conn("message/send", message_params())
        |> A2A.Plug.call(opts)

      assert conn.status == 200
      body = json_body(conn)
      assert body["result"]["task"]["kind"] == "task"
    end

    test "response includes A2A-Extensions header with all supported URIs", %{opts: opts} do
      conn =
        json_rpc_conn("message/send", message_params())
        |> A2A.Plug.call(opts)

      [header] = get_resp_header(conn, "a2a-extensions")
      uris = String.split(header, ", ")
      assert "https://example.com/ext/timestamp" in uris
      assert "https://example.com/ext/tracing" in uris
    end
  end

  # -- Extension negotiation: required extensions ------------------------------

  describe "required extensions" do
    setup %{agent: agent} do
      extensions = [
        %AgentExtension{
          uri: "https://example.com/ext/passport",
          required: true,
          description: "Secure passport required"
        },
        %AgentExtension{
          uri: "https://example.com/ext/timestamp",
          required: false
        }
      ]

      opts = plug_opts(agent, extensions: extensions)
      {:ok, opts: opts}
    end

    test "returns ExtensionSupportRequiredError when client missing required extension",
         %{opts: opts} do
      conn =
        json_rpc_conn("message/send", message_params())
        |> A2A.Plug.call(opts)

      assert conn.status == 200
      body = json_body(conn)
      assert body["error"]["code"] == -32_008
      assert body["error"]["message"] == "Extension support required"
      assert body["error"]["data"] =~ "https://example.com/ext/passport"
    end

    test "succeeds when client declares required extension", %{opts: opts} do
      conn =
        json_rpc_conn("message/send", message_params())
        |> Plug.Conn.put_req_header(
          "a2a-extensions",
          "https://example.com/ext/passport"
        )
        |> A2A.Plug.call(opts)

      assert conn.status == 200
      body = json_body(conn)
      assert body["result"]["task"]["kind"] == "task"
    end

    test "succeeds when client declares multiple extensions including required", %{opts: opts} do
      conn =
        json_rpc_conn("message/send", message_params())
        |> Plug.Conn.put_req_header(
          "a2a-extensions",
          "https://example.com/ext/passport, https://example.com/ext/other"
        )
        |> A2A.Plug.call(opts)

      assert conn.status == 200
      body = json_body(conn)
      assert body["result"]["task"]["kind"] == "task"
    end

    test "response includes all supported extension URIs in header", %{opts: opts} do
      conn =
        json_rpc_conn("message/send", message_params())
        |> Plug.Conn.put_req_header(
          "a2a-extensions",
          "https://example.com/ext/passport"
        )
        |> A2A.Plug.call(opts)

      [header] = get_resp_header(conn, "a2a-extensions")
      uris = String.split(header, ", ")
      assert "https://example.com/ext/passport" in uris
      assert "https://example.com/ext/timestamp" in uris
    end
  end

  # -- Extension negotiation: multiple required extensions ---------------------

  describe "multiple required extensions" do
    setup %{agent: agent} do
      extensions = [
        %AgentExtension{uri: "https://example.com/ext/a", required: true},
        %AgentExtension{uri: "https://example.com/ext/b", required: true}
      ]

      opts = plug_opts(agent, extensions: extensions)
      {:ok, opts: opts}
    end

    test "fails when client only declares one of two required extensions", %{opts: opts} do
      conn =
        json_rpc_conn("message/send", message_params())
        |> Plug.Conn.put_req_header("a2a-extensions", "https://example.com/ext/a")
        |> A2A.Plug.call(opts)

      body = json_body(conn)
      assert body["error"]["code"] == -32_008
      assert body["error"]["data"] =~ "https://example.com/ext/b"
    end

    test "succeeds when client declares both required extensions", %{opts: opts} do
      conn =
        json_rpc_conn("message/send", message_params())
        |> Plug.Conn.put_req_header(
          "a2a-extensions",
          "https://example.com/ext/a, https://example.com/ext/b"
        )
        |> A2A.Plug.call(opts)

      assert conn.status == 200
      body = json_body(conn)
      assert body["result"]["task"]["kind"] == "task"
    end
  end

  # -- Client extensions -------------------------------------------------------

  describe "client extensions" do
    test "new/2 stores extensions and sends A2A-Extensions header" do
      client =
        A2A.Client.new("http://localhost:4000",
          extensions: ["https://example.com/ext/a", "https://example.com/ext/b"],
          plug: {A2A.Plug, plug_opts(self())}
        )

      assert client.extensions == ["https://example.com/ext/a", "https://example.com/ext/b"]

      # Verify the header is set in the Req request
      headers = client.req.headers
      ext_header = Map.get(headers, "a2a-extensions")
      assert ext_header == ["https://example.com/ext/a, https://example.com/ext/b"]
    end

    test "new/2 without extensions does not set header" do
      client = A2A.Client.new("http://localhost:4000")
      assert client.extensions == []

      headers = client.req.headers
      assert Map.get(headers, "a2a-extensions") == nil
    end
  end
end
