defmodule A2A.PushNotificationTest do
  use ExUnit.Case, async: true

  alias A2A.PushNotificationConfig

  defp start_agent(sender_opts) do
    start_supervised!(
      {A2A.Test.MultiTurnAgent, [name: nil, push_sender: {A2A.Test.PushSender, sender_opts}]}
    )
  end

  defp register_config(agent, task_id) do
    config = %PushNotificationConfig{
      id: "pcfg-1",
      task_id: task_id,
      url: "https://example.com/hook"
    }

    {:ok, _} = GenServer.call(agent, {:set_push_config, config})
  end

  describe "delivery on task state change" do
    test "posts a status update to every registered webhook" do
      agent = start_agent(pid: self())
      # The first turn parks the task in input-required; registering the
      # webhook then, and completing on the second turn, is the flow the
      # compliance suite drives.
      {:ok, task} = A2A.call(agent, "order")
      register_config(agent, task.id)

      {:ok, _task} = A2A.call(agent, "large", task_id: task.id)

      assert_receive {:push_delivered, config, payload}, 1_000
      assert config.id == "pcfg-1"
      assert %{"statusUpdate" => update} = payload
      assert update["taskId"] == task.id
      assert update["status"]["state"] == "TASK_STATE_COMPLETED"
    end

    test "delivers once per registered config" do
      agent = start_agent(pid: self())
      {:ok, task} = A2A.call(agent, "order")

      for id <- ["pcfg-a", "pcfg-b"] do
        config = %PushNotificationConfig{id: id, task_id: task.id, url: "https://e.test/#{id}"}
        {:ok, _} = GenServer.call(agent, {:set_push_config, config})
      end

      {:ok, _} = A2A.call(agent, "large", task_id: task.id)

      assert_receive {:push_delivered, %{id: first}, _}, 1_000
      assert_receive {:push_delivered, %{id: second}, _}, 1_000
      assert Enum.sort([first, second]) == ["pcfg-a", "pcfg-b"]
    end

    test "is a no-op for a task with no configs" do
      agent = start_agent(pid: self())
      {:ok, _task} = A2A.call(agent, "order")

      refute_receive {:push_delivered, _, _}, 200
    end

    test "is a no-op when the agent has no sender" do
      agent = start_supervised!({A2A.Test.MultiTurnAgent, [name: nil, push_sender: nil]})
      {:ok, task} = A2A.call(agent, "order")
      register_config(agent, task.id)
      {:ok, _} = A2A.call(agent, "large", task_id: task.id)

      refute_receive {:push_delivered, _, _}, 200
    end

    test "a failing sender does not disturb the agent" do
      agent = start_agent(pid: self(), result: {:error, :boom})
      {:ok, task} = A2A.call(agent, "order")
      register_config(agent, task.id)

      {:ok, _} = A2A.call(agent, "large", task_id: task.id)
      assert_receive {:push_delivered, _, _}, 1_000

      # Delivery runs off-process, so a rejected webhook must leave the agent
      # answering normally.
      assert {:ok, _} = A2A.call(agent, "still alive")
    end

    test "a task that finishes in one turn still gets a delivery" do
      agent =
        start_supervised!(
          {A2A.Test.EchoAgent, [name: nil, push_sender: {A2A.Test.PushSender, pid: self()}]}
        )

      opts =
        A2A.Plug.init(
          agent: agent,
          base_url: "http://localhost:4000",
          agent_card_opts: [capabilities: %{push_notifications: true}]
        )

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "message/send",
          "params" => %{
            "message" => %{
              "messageId" => "msg-1",
              "role" => "user",
              "parts" => [%{"kind" => "text", "text" => "hi"}]
            },
            "configuration" => %{
              "taskPushNotificationConfig" => %{"url" => "https://example.com/hook"}
            }
          }
        })

      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> A2A.Plug.call(opts)

      # Every transition happened before the webhook was registered, so
      # without a catch-up this config would never receive anything.
      assert_receive {:push_delivered, _config, payload}, 1_000
      assert %{"statusUpdate" => update} = payload
      assert update["status"]["state"] == "TASK_STATE_COMPLETED"
    end

    test "emits delivery telemetry" do
      handler = "push-delivery-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:a2a, :push_notification, :delivery],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      agent = start_agent(pid: self())
      {:ok, task} = A2A.call(agent, "order")
      register_config(agent, task.id)
      {:ok, _} = A2A.call(agent, "large", task_id: task.id)

      assert_receive {:telemetry, measurements, metadata}, 1_000
      assert is_integer(measurements.duration)
      assert metadata.task_id == task.id
      assert metadata.config_id == "pcfg-1"
      assert metadata.result == :ok
    end
  end
end
