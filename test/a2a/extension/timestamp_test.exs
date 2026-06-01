defmodule A2A.Extension.TimestampTest do
  use ExUnit.Case, async: true

  alias A2A.Client
  alias A2A.Extension.Timestamp

  setup do
    agent = start_supervised!({A2A.Test.EchoAgent, [name: nil]})
    {:ok, agent: agent}
  end

  test "uri/0 returns the stable public URI" do
    assert Timestamp.uri() == "https://a2a-protocol.org/extensions/timestamp/v1"
  end

  test "declares a non-required AgentExtension" do
    %A2A.AgentExtension{uri: uri, required: false, description: desc} =
      Timestamp.declaration(nil)

    assert uri == Timestamp.uri()
    assert is_binary(desc)
  end

  test "round-trips through Plug and Client", %{agent: agent} do
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

    before_ms = System.system_time(:millisecond)
    {:ok, task} = Client.send_message(client, "hi")
    after_ms = System.system_time(:millisecond)

    stamp = task.metadata[Timestamp.uri()]
    assert is_map(stamp)
    assert is_integer(stamp["received_at"])
    assert is_integer(stamp["completed_at"])

    assert stamp["received_at"] >= before_ms
    assert stamp["completed_at"] >= stamp["received_at"]
    assert stamp["completed_at"] <= after_ms
  end

  test "agent card advertises the extension", %{agent: agent} do
    opts =
      A2A.Plug.init(
        agent: agent,
        base_url: "http://localhost:4000",
        extensions: [Timestamp]
      )

    conn =
      Plug.Test.conn(:get, "/.well-known/agent-card.json")
      |> A2A.Plug.call(opts)

    card = Jason.decode!(conn.resp_body)

    assert [
             %{
               "uri" => "https://a2a-protocol.org/extensions/timestamp/v1",
               "required" => false
             }
           ] = card["capabilities"]["extensions"]
  end
end
