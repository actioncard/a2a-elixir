defmodule A2A.PushNotificationSender.HTTPTest do
  use ExUnit.Case, async: true

  alias A2A.PushNotificationConfig
  alias A2A.PushNotificationSender.HTTP

  @payload %{"statusUpdate" => %{"taskId" => "tsk-1", "status" => %{"state" => "completed"}}}

  defp start_receiver(opts \\ []) do
    test_pid = self()
    statuses = Keyword.get(opts, :statuses, [200])
    counter = :counters.new(1, [])

    plug = fn conn, _opts ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      :counters.add(counter, 1, 1)
      index = :counters.get(counter, 1)

      send(test_pid, {:webhook, conn.req_headers, body})

      status = Enum.at(statuses, index - 1, List.last(statuses))
      Plug.Conn.send_resp(conn, status, "")
    end

    # Linked to the test process, so it goes down with the test.
    {:ok, server} = Bandit.start_link(plug: plug, port: 0, ip: :loopback)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    {"http://127.0.0.1:#{port}/webhook", counter}
  end

  describe "deliver/3" do
    @tag timeout: 10_000
    test "posts the payload as JSON" do
      {url, _} = start_receiver()
      config = %PushNotificationConfig{id: "pcfg-1", task_id: "tsk-1", url: url}

      assert :ok = HTTP.deliver(config, @payload, [])

      assert_receive {:webhook, headers, body}, 2_000
      assert Jason.decode!(body) == @payload
      assert {_, "application/json"} = List.keyfind(headers, "content-type", 0)
    end

    @tag timeout: 10_000
    test "sends the configured credentials as an Authorization header" do
      {url, _} = start_receiver()

      config = %PushNotificationConfig{
        id: "pcfg-1",
        task_id: "tsk-1",
        url: url,
        authentication: %{scheme: "Bearer", credentials: "tck-test-token-abc"}
      }

      assert :ok = HTTP.deliver(config, @payload, [])

      assert_receive {:webhook, headers, _body}, 2_000
      assert {_, "Bearer tck-test-token-abc"} = List.keyfind(headers, "authorization", 0)
    end

    @tag timeout: 10_000
    test "falls back to the v0.3 token field" do
      {url, _} = start_receiver()
      config = %PushNotificationConfig{id: "p", task_id: "t", url: url, token: "legacy"}

      assert :ok = HTTP.deliver(config, @payload, [])

      assert_receive {:webhook, headers, _body}, 2_000
      assert {_, "Bearer legacy"} = List.keyfind(headers, "authorization", 0)
    end

    @tag timeout: 10_000
    test "sends no Authorization header when the config carries no credentials" do
      {url, _} = start_receiver()
      config = %PushNotificationConfig{id: "p", task_id: "t", url: url}

      assert :ok = HTTP.deliver(config, @payload, [])

      assert_receive {:webhook, headers, _body}, 2_000
      refute List.keyfind(headers, "authorization", 0)
    end

    @tag timeout: 10_000
    test "retries a failing webhook and succeeds when it recovers" do
      {url, counter} = start_receiver(statuses: [500, 500, 200])
      config = %PushNotificationConfig{id: "p", task_id: "t", url: url}

      assert :ok = HTTP.deliver(config, @payload, attempts: 3)
      assert :counters.get(counter, 1) == 3
    end

    @tag timeout: 10_000
    test "gives up after the attempt budget and reports the status" do
      {url, counter} = start_receiver(statuses: [503])
      config = %PushNotificationConfig{id: "p", task_id: "t", url: url}

      assert {:error, {:http_status, 503}} = HTTP.deliver(config, @payload, attempts: 2)
      assert :counters.get(counter, 1) == 2
    end
  end

  describe "url hardening" do
    test "is off by default, so a localhost webhook is allowed" do
      {url, _} = start_receiver()
      config = %PushNotificationConfig{id: "p", task_id: "t", url: url}

      assert :ok = HTTP.deliver(config, @payload, [])
    end

    test "rejects plain HTTP when require_https is set" do
      config = %PushNotificationConfig{id: "p", task_id: "t", url: "http://example.com/hook"}

      assert {:error, {:insecure_url, _}} =
               HTTP.deliver(config, @payload, require_https: true)
    end

    test "rejects private and loopback hosts when block_private_ips is set" do
      for host <- ["localhost", "127.0.0.1", "10.1.2.3", "192.168.1.1", "172.16.0.1"] do
        config = %PushNotificationConfig{id: "p", task_id: "t", url: "https://#{host}/hook"}

        assert {:error, {:private_host, _}} =
                 HTTP.deliver(config, @payload, block_private_ips: true),
               "expected #{host} to be blocked"
      end
    end
  end
end
