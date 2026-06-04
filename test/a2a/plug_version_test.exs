defmodule A2A.PlugVersionTest do
  use ExUnit.Case, async: true

  @moduletag :plug

  defp plug_opts(agent, extra \\ []) do
    A2A.Plug.init([agent: agent, base_url: "http://localhost:4000"] ++ extra)
  end

  defp json_rpc_conn(method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => method,
        "params" => params
      })

    Plug.Test.conn(:post, "/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  defp message_params do
    %{
      "message" => %{
        "messageId" => "msg-test",
        "role" => "user",
        "parts" => [%{"kind" => "text", "text" => "hi"}]
      }
    }
  end

  defp send_message(opts, version_header \\ :unset) do
    conn = json_rpc_conn("message/send", message_params())

    conn =
      case version_header do
        :unset -> conn
        nil -> conn
        value -> Plug.Conn.put_req_header(conn, "a2a-version", value)
      end

    A2A.Plug.call(conn, opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)
  defp get_resp_header(conn, key), do: for({k, v} <- conn.resp_headers, k == key, do: v)

  setup do
    agent = start_supervised!({A2A.Test.EchoAgent, [name: nil]})
    {:ok, agent: agent}
  end

  describe "default supported versions" do
    setup %{agent: agent}, do: {:ok, opts: plug_opts(agent)}

    test "accepts 1.0", %{opts: opts} do
      conn = send_message(opts, "1.0")
      assert conn.status == 200
      assert json_body(conn)["result"]
      assert get_resp_header(conn, "a2a-version") == ["1.0"]
    end

    test "accepts 0.3", %{opts: opts} do
      conn = send_message(opts, "0.3")
      assert conn.status == 200
      assert get_resp_header(conn, "a2a-version") == ["0.3"]
    end

    test "treats missing header as 0.3", %{opts: opts} do
      conn = send_message(opts)
      assert conn.status == 200
      assert get_resp_header(conn, "a2a-version") == ["0.3"]
    end

    test "treats empty header as 0.3", %{opts: opts} do
      conn = send_message(opts, "")
      assert conn.status == 200
      assert get_resp_header(conn, "a2a-version") == ["0.3"]
    end

    test "strips patch components before validating", %{opts: opts} do
      conn = send_message(opts, "1.0.3")
      assert conn.status == 200
      assert get_resp_header(conn, "a2a-version") == ["1.0"]
    end

    test "rejects an unknown version with -32009", %{opts: opts} do
      conn = send_message(opts, "9.9")
      body = json_body(conn)
      assert body["error"]["code"] == -32_009
      assert body["error"]["data"] == "9.9"
      assert get_resp_header(conn, "a2a-version") == []
    end

    test "rejects garbage values with -32009", %{opts: opts} do
      conn = send_message(opts, "abc")
      body = json_body(conn)
      assert body["error"]["code"] == -32_009
      assert body["error"]["data"] == "abc"
    end
  end

  describe "custom :versions list" do
    test "narrows acceptance", %{agent: agent} do
      opts = plug_opts(agent, versions: ["1.0"])

      ok = send_message(opts, "1.0")
      assert ok.status == 200

      bad = send_message(opts, "0.3")
      body = json_body(bad)
      assert body["error"]["code"] == -32_009
      assert body["error"]["data"] == "0.3"
    end

    test "also rejects the missing-header 0.3 default when 0.3 is unsupported",
         %{agent: agent} do
      opts = plug_opts(agent, versions: ["1.0"])
      conn = send_message(opts)
      body = json_body(conn)
      assert body["error"]["code"] == -32_009
      assert body["error"]["data"] == "0.3"
    end
  end

  describe "streaming requests" do
    test "version is validated on SendStreamingMessage", %{agent: agent} do
      opts = plug_opts(agent)

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "SendStreamingMessage",
          "params" => message_params()
        })

      conn =
        Plug.Test.conn(:post, "/", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("a2a-version", "9.9")
        |> A2A.Plug.call(opts)

      assert json_body(conn)["error"]["code"] == -32_009
    end
  end

  describe "ordering vs extensions" do
    setup %{agent: agent} do
      defmodule RequiredExt do
        @moduledoc false
        @behaviour A2A.Extension
        def declaration(_),
          do: %A2A.AgentExtension{uri: "https://example.test/ext/req-only", required: true}
      end

      opts = plug_opts(agent, extensions: [RequiredExt])
      {:ok, opts: opts}
    end

    test "version is checked before required-extension validation", %{opts: opts} do
      # Bad version + missing required extension → -32009 (version) wins
      conn = send_message(opts, "9.9")
      body = json_body(conn)
      assert body["error"]["code"] == -32_009
    end
  end
end
