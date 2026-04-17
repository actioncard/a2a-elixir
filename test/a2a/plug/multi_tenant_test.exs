defmodule A2A.Plug.MultiTenantTest do
  use ExUnit.Case, async: true

  @moduletag :plug

  defp mt_opts(agents, extra \\ []) do
    A2A.Plug.MultiTenant.init([agents: agents, base_url: "http://localhost:4000"] ++ extra)
  end

  defp json_rpc_conn(method, path, params \\ %{}, id \\ 1) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      })

    Plug.Test.conn(:post, path, body)
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

  defp get_resp_header(conn, key) do
    for {k, v} <- conn.resp_headers, k == key, do: v
  end

  setup do
    echo = start_supervised!({A2A.Test.EchoAgent, [name: nil]}, id: :echo)
    greeter = start_supervised!({A2A.Test.GreeterAgent, [name: nil]}, id: :greeter)
    {:ok, echo: echo, greeter: greeter}
  end

  describe "path-based routing" do
    test "routes /:tenant/:agent to correct agent", %{echo: echo, greeter: greeter} do
      agents = %{"echo" => echo, "greeter" => greeter}
      opts = mt_opts(agents)

      conn =
        json_rpc_conn("message/send", "/acme/echo/", message_params("hi"))
        |> A2A.Plug.MultiTenant.call(opts)

      assert conn.status == 200
      body = json_body(conn)
      assert body["result"]["task"]["status"]["state"] == "TASK_STATE_COMPLETED"

      artifact = hd(body["result"]["task"]["artifacts"])
      assert hd(artifact["parts"])["text"] == "hi"
    end

    test "different tenants use same agent", %{echo: echo} do
      agents = %{"echo" => echo}
      opts = mt_opts(agents)

      conn1 =
        json_rpc_conn("message/send", "/tenant-a/echo/", message_params("from A"))
        |> A2A.Plug.MultiTenant.call(opts)

      conn2 =
        json_rpc_conn("message/send", "/tenant-b/echo/", message_params("from B"))
        |> A2A.Plug.MultiTenant.call(opts)

      assert conn1.status == 200
      assert conn2.status == 200

      body1 = json_body(conn1)
      body2 = json_body(conn2)

      artifact1 = hd(body1["result"]["task"]["artifacts"])
      artifact2 = hd(body2["result"]["task"]["artifacts"])
      assert hd(artifact1["parts"])["text"] == "from A"
      assert hd(artifact2["parts"])["text"] == "from B"
    end

    test "unknown agent returns 404", %{echo: echo} do
      agents = %{"echo" => echo}
      opts = mt_opts(agents)

      conn =
        Plug.Test.conn(:post, "/acme/nonexistent/", "")
        |> A2A.Plug.MultiTenant.call(opts)

      assert conn.status == 404
      assert conn.resp_body =~ "Agent not found"
    end

    test "missing path segments returns 404" do
      opts = mt_opts(%{"echo" => self()})

      conn =
        Plug.Test.conn(:get, "/only-one-segment")
        |> A2A.Plug.MultiTenant.call(opts)

      assert conn.status == 404
    end
  end

  describe "tenant context" do
    test "injects tenant_id into task metadata", %{echo: echo} do
      agents = %{"echo" => echo}
      opts = mt_opts(agents)

      conn =
        json_rpc_conn("message/send", "/acme/echo/", message_params())
        |> A2A.Plug.MultiTenant.call(opts)

      body = json_body(conn)
      meta = body["result"]["task"]["metadata"]
      assert meta["tenant_id"] == "acme"
    end

    test "sets conn assigns for tenant and agent", %{echo: echo} do
      agents = %{"echo" => echo}
      opts = mt_opts(agents)

      conn =
        json_rpc_conn("message/send", "/acme/echo/", message_params())
        |> A2A.Plug.MultiTenant.call(opts)

      assert conn.assigns[:a2a_tenant] == "acme"
      assert conn.assigns[:a2a_agent_name] == "echo"
    end
  end

  describe "agent card per-tenant" do
    test "serves agent card with tenant-scoped URL", %{echo: echo} do
      agents = %{"echo" => echo}
      opts = mt_opts(agents)

      conn =
        Plug.Test.conn(:get, "/acme/echo/.well-known/agent-card.json")
        |> A2A.Plug.MultiTenant.call(opts)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"

      body = json_body(conn)
      assert body["name"] == "echo"
      assert body["url"] == "http://localhost:4000/acme/echo"
    end

    test "different tenants get different URLs", %{echo: echo} do
      agents = %{"echo" => echo}
      opts = mt_opts(agents)

      conn_a =
        Plug.Test.conn(:get, "/tenant-a/echo/.well-known/agent-card.json")
        |> A2A.Plug.MultiTenant.call(opts)

      conn_b =
        Plug.Test.conn(:get, "/tenant-b/echo/.well-known/agent-card.json")
        |> A2A.Plug.MultiTenant.call(opts)

      assert json_body(conn_a)["url"] == "http://localhost:4000/tenant-a/echo"
      assert json_body(conn_b)["url"] == "http://localhost:4000/tenant-b/echo"
    end
  end

  describe "registry-based lookup" do
    setup do
      registry = :"test_registry_#{System.unique_integer([:positive])}"
      echo = start_supervised!({A2A.Test.EchoAgent, [name: nil]}, id: :reg_echo)

      _ =
        start_supervised!(
          {A2A.Registry, name: registry, agents: []},
          id: :reg
        )

      A2A.Registry.register(registry, echo, A2A.Test.EchoAgent.agent_card())

      {:ok, registry: registry, echo: echo}
    end

    test "resolves agent by card name from registry", %{registry: registry} do
      opts =
        A2A.Plug.MultiTenant.init(
          registry: registry,
          base_url: "http://localhost:4000"
        )

      conn =
        json_rpc_conn("message/send", "/acme/echo/", message_params("via registry"))
        |> A2A.Plug.MultiTenant.call(opts)

      assert conn.status == 200
      body = json_body(conn)
      artifact = hd(body["result"]["task"]["artifacts"])
      assert hd(artifact["parts"])["text"] == "via registry"
    end

    test "returns 404 for unregistered agent", %{registry: registry} do
      opts =
        A2A.Plug.MultiTenant.init(
          registry: registry,
          base_url: "http://localhost:4000"
        )

      conn =
        Plug.Test.conn(:post, "/acme/unknown/", "")
        |> A2A.Plug.MultiTenant.call(opts)

      assert conn.status == 404
    end
  end

  describe "init/1" do
    test "raises without agents or registry" do
      assert_raise ArgumentError, ~r/requires either/, fn ->
        A2A.Plug.MultiTenant.init(base_url: "http://localhost:4000")
      end
    end

    test "raises without base_url" do
      assert_raise KeyError, fn ->
        A2A.Plug.MultiTenant.init(agents: %{"echo" => self()})
      end
    end
  end

  describe "backward compatibility" do
    test "A2A.Plug still works standalone", %{echo: echo} do
      opts = A2A.Plug.init(agent: echo, base_url: "http://localhost:4000")

      conn =
        Plug.Test.conn(
          :post,
          "/",
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "message/send",
            "params" => message_params()
          })
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> A2A.Plug.call(opts)

      assert conn.status == 200
      body = json_body(conn)
      assert body["result"]["task"]["kind"] == "task"
    end
  end
end
