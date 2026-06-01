defmodule A2A.PlugExtensionTest do
  use ExUnit.Case, async: true

  @moduletag :plug

  alias A2A.Test.Extensions.{DataOnly, Passport, Timestamp}

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

  defp message_params(text \\ "hello") do
    %{
      "message" => %{
        "messageId" => "msg-test",
        "role" => "user",
        "parts" => [%{"kind" => "text", "text" => text}]
      }
    }
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)
  defp get_resp_header(conn, key), do: for({k, v} <- conn.resp_headers, k == key, do: v)

  setup do
    agent = start_supervised!({A2A.Test.EchoAgent, [name: nil]})
    {:ok, agent: agent}
  end

  describe "no extensions configured" do
    test "requests succeed without A2A-Extensions header", %{agent: agent} do
      conn =
        json_rpc_conn("message/send", message_params())
        |> A2A.Plug.call(plug_opts(agent))

      assert conn.status == 200
      assert get_resp_header(conn, "a2a-extensions") == []
    end
  end

  describe "optional extension activation" do
    setup %{agent: agent} do
      opts = plug_opts(agent, extensions: [Timestamp])
      {:ok, opts: opts}
    end

    test "does not activate when client omits the header", %{opts: opts} do
      conn =
        json_rpc_conn("message/send", message_params())
        |> A2A.Plug.call(opts)

      assert conn.status == 200
      assert get_resp_header(conn, "a2a-extensions") == []
    end

    test "activates and echoes the URI when client declares it", %{opts: opts} do
      conn =
        json_rpc_conn("message/send", message_params())
        |> Plug.Conn.put_req_header(
          "a2a-extensions",
          "https://example.test/ext/timestamp"
        )
        |> A2A.Plug.call(opts)

      assert conn.status == 200
      assert get_resp_header(conn, "a2a-extensions") == ["https://example.test/ext/timestamp"]

      # handle_response mutated task metadata under the URI
      task = json_body(conn)["result"]["task"]

      assert task["metadata"]["https://example.test/ext/timestamp"] ==
               %{"finished_at" => 1_700_000_000_000}
    end

    test "handle_request runs and may mutate the message", %{opts: opts} do
      # Reuses the same hook chain — the message has put_metadata applied
      # before reaching the agent. The agent doesn't see it directly in
      # this echo test, but the request hook returned :ok so the round
      # trip succeeds.
      conn =
        json_rpc_conn("message/send", message_params("hi"))
        |> Plug.Conn.put_req_header("a2a-extensions", "https://example.test/ext/timestamp")
        |> A2A.Plug.call(opts)

      assert conn.status == 200
      assert json_body(conn)["result"]["task"]["status"]["state"] == "TASK_STATE_COMPLETED"
    end
  end

  describe "required extension validation" do
    setup %{agent: agent} do
      opts = plug_opts(agent, extensions: [Passport, Timestamp])
      {:ok, opts: opts}
    end

    test "returns -32008 when client misses required URI", %{opts: opts} do
      conn =
        json_rpc_conn("message/send", message_params())
        |> A2A.Plug.call(opts)

      body = json_body(conn)
      assert body["error"]["code"] == -32_008
      assert body["error"]["data"] =~ "https://example.test/ext/passport"
    end

    test "succeeds when required URI is in client header", %{opts: opts} do
      conn =
        json_rpc_conn("message/send", message_params())
        |> Plug.Conn.put_req_header(
          "a2a-extensions",
          "https://example.test/ext/passport, https://example.test/ext/timestamp"
        )
        |> A2A.Plug.call(opts)

      assert conn.status == 200
      body = json_body(conn)
      assert body["result"]["task"]["status"]["state"] == "TASK_STATE_COMPLETED"

      activated = hd(get_resp_header(conn, "a2a-extensions")) |> String.split(", ")
      assert "https://example.test/ext/passport" in activated
      assert "https://example.test/ext/timestamp" in activated
    end
  end

  describe "multiple required extensions" do
    setup %{agent: agent} do
      defmodule RequiredA do
        @moduledoc false
        @behaviour A2A.Extension
        def declaration(_),
          do: %A2A.AgentExtension{uri: "https://example.test/ext/req-a", required: true}
      end

      defmodule RequiredB do
        @moduledoc false
        @behaviour A2A.Extension
        def declaration(_),
          do: %A2A.AgentExtension{uri: "https://example.test/ext/req-b", required: true}
      end

      opts = plug_opts(agent, extensions: [RequiredA, RequiredB])
      {:ok, opts: opts}
    end

    test "fails when only one of two required is declared", %{opts: opts} do
      conn =
        json_rpc_conn("message/send", message_params())
        |> Plug.Conn.put_req_header("a2a-extensions", "https://example.test/ext/req-a")
        |> A2A.Plug.call(opts)

      body = json_body(conn)
      assert body["error"]["code"] == -32_008
      assert body["error"]["data"] =~ "req-b"
    end
  end

  describe "agent card advertises configured extensions" do
    test "merges extension declarations into capabilities.extensions", %{agent: agent} do
      opts = plug_opts(agent, extensions: [Timestamp, DataOnly])

      conn =
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> A2A.Plug.call(opts)

      assert conn.status == 200
      card = json_body(conn)

      assert [
               %{
                 "uri" => "https://example.test/ext/timestamp",
                 "required" => false,
                 "description" => "Adds timestamps"
               },
               %{
                 "uri" => "https://example.test/ext/data-only",
                 "required" => false,
                 "description" => "Pure declaration, no hooks",
                 "params" => %{"category" => "data-only"}
               }
             ] = card["capabilities"]["extensions"]
    end

    test "does not duplicate when agent_card_opts already declared the URI", %{agent: agent} do
      pre_declared = %A2A.AgentExtension{
        uri: "https://example.test/ext/timestamp",
        description: "Pre-existing",
        required: true
      }

      opts =
        plug_opts(agent,
          extensions: [Timestamp],
          agent_card_opts: [capabilities: %{extensions: [pre_declared]}]
        )

      conn =
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> A2A.Plug.call(opts)

      card = json_body(conn)
      # Pre-existing declaration wins; Timestamp not duplicated
      assert card["capabilities"]["extensions"] == [
               %{
                 "uri" => "https://example.test/ext/timestamp",
                 "required" => true,
                 "description" => "Pre-existing"
               }
             ]
    end
  end

  describe "extension activations surface to agent context" do
    defmodule ExtAwareAgent do
      @moduledoc false
      use A2A.Agent, name: "ext-aware", skills: []

      @impl A2A.Agent
      def handle_message(_message, context) do
        activated = Map.keys(context.extensions) |> Enum.sort()
        {:reply, [A2A.Part.Text.new(Enum.join(activated, ","))]}
      end
    end

    test "handle_message sees activations keyed by URI" do
      agent = start_supervised!({ExtAwareAgent, [name: nil]})
      opts = plug_opts(agent, extensions: [Timestamp, DataOnly])

      conn =
        json_rpc_conn("message/send", message_params())
        |> Plug.Conn.put_req_header(
          "a2a-extensions",
          "https://example.test/ext/timestamp, https://example.test/ext/data-only"
        )
        |> A2A.Plug.call(opts)

      task = json_body(conn)["result"]["task"]
      [%{"parts" => [%{"text" => text}]}] = task["artifacts"]

      assert text ==
               Enum.join(
                 [
                   "https://example.test/ext/data-only",
                   "https://example.test/ext/timestamp"
                 ],
                 ","
               )
    end
  end
end
