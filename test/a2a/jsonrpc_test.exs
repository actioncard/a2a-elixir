defmodule A2A.JSONRPCTest do
  use ExUnit.Case, async: true

  alias A2A.JSONRPC

  @handler A2A.Test.Handler
  @push_handler A2A.Test.PushHandler

  defp rpc(method, params \\ %{}, id \\ 1) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
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

  # -- message/send ----------------------------------------------------------

  describe "message/send" do
    test "valid request returns success with wrapped task result" do
      {:reply, response} = JSONRPC.handle(rpc("message/send", message_params()), @handler)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert %{"task" => task} = response["result"]
      refute Map.has_key?(task, "kind")
      assert task["status"]["state"] == "TASK_STATE_COMPLETED"
      assert [msg] = task["history"]
      refute Map.has_key?(msg, "kind")
      assert msg["role"] == "ROLE_USER"
    end

    test "message reply is wrapped in a message result" do
      params = put_in(message_params()["message"]["messageId"], "msg-bare")
      {:reply, response} = JSONRPC.handle(rpc("message/send", params), @handler)

      assert %{"message" => msg} = response["result"]
      refute Map.has_key?(response["result"], "task")
      assert msg["role"] == "ROLE_AGENT"
      assert msg["parts"] == [%{"text" => "bare reply"}]
      assert is_binary(msg["messageId"])
      refute Map.has_key?(msg, "kind")
      refute Map.has_key?(msg, "taskId")
    end

    test "historyLength does not apply to a message reply" do
      params =
        message_params()
        |> put_in(["message", "messageId"], "msg-bare")
        |> Map.put("configuration", %{"historyLength" => 1})

      {:reply, response} = JSONRPC.handle(rpc("message/send", params), @handler)

      assert %{"message" => %{"parts" => [%{"text" => "bare reply"}]}} = response["result"]
    end

    test "bad message returns invalid_params" do
      params = %{"message" => "not a map"}
      {:reply, response} = JSONRPC.handle(rpc("message/send", params), @handler)

      assert response["error"]["code"] == -32_602
    end

    test "missing message returns invalid_params" do
      {:reply, response} = JSONRPC.handle(rpc("message/send", %{}), @handler)

      assert response["error"]["code"] == -32_602
    end

    test "malformed message body returns invalid_params" do
      params = %{"message" => %{"role" => "user"}}
      {:reply, response} = JSONRPC.handle(rpc("message/send", params), @handler)

      assert response["error"]["code"] == -32_602
    end
  end

  # -- tasks/get -------------------------------------------------------------

  describe "tasks/get" do
    test "existing task returns success" do
      params = %{"id" => "existing"}
      {:reply, response} = JSONRPC.handle(rpc("tasks/get", params), @handler)

      assert response["result"]["id"] == "existing"
      assert response["result"]["status"]["state"] == "TASK_STATE_WORKING"
    end

    test "missing task returns task_not_found" do
      params = %{"id" => "nonexistent"}
      {:reply, response} = JSONRPC.handle(rpc("tasks/get", params), @handler)

      assert response["error"]["code"] == -32_001
    end

    test "missing id param returns invalid_params" do
      {:reply, response} = JSONRPC.handle(rpc("tasks/get", %{}), @handler)

      assert response["error"]["code"] == -32_602
    end
  end

  # -- tasks/cancel ----------------------------------------------------------

  describe "tasks/cancel" do
    test "cancelable task returns success" do
      params = %{"id" => "cancelable"}
      {:reply, response} = JSONRPC.handle(rpc("tasks/cancel", params), @handler)

      assert response["result"]["id"] == "cancelable"
      assert response["result"]["status"]["state"] == "TASK_STATE_CANCELED"
    end

    test "non-cancelable task returns task_not_cancelable" do
      params = %{"id" => "locked"}
      {:reply, response} = JSONRPC.handle(rpc("tasks/cancel", params), @handler)

      assert response["error"]["code"] == -32_002
    end
  end

  # -- streaming methods -----------------------------------------------------

  describe "message/stream" do
    test "returns stream tuple with decoded message" do
      result = JSONRPC.handle(rpc("message/stream", message_params("hi")), @handler)

      assert {:stream, "message/stream", params, 1} = result
      assert %A2A.Message{} = params["message"]
    end

    test "bad message returns error reply" do
      params = %{"message" => "not a map"}
      {:reply, response} = JSONRPC.handle(rpc("message/stream", params), @handler)

      assert response["error"]["code"] == -32_602
    end
  end

  describe "tasks/resubscribe" do
    test "returns stream tuple" do
      params = %{"id" => "tsk-1"}
      result = JSONRPC.handle(rpc("tasks/resubscribe", params), @handler)

      assert {:stream, "tasks/resubscribe", ^params, 1} = result
    end
  end

  # -- unsupported methods ---------------------------------------------------

  describe "push notification methods without push callbacks" do
    test "pushNotificationConfig/set returns unsupported" do
      {:reply, response} =
        JSONRPC.handle(rpc("tasks/pushNotificationConfig/set"), @handler)

      assert response["error"]["code"] == -32_003
    end

    test "pushNotificationConfig/get returns unsupported" do
      {:reply, response} =
        JSONRPC.handle(rpc("tasks/pushNotificationConfig/get"), @handler)

      assert response["error"]["code"] == -32_003
    end

    test "pushNotificationConfig/list returns unsupported" do
      {:reply, response} =
        JSONRPC.handle(rpc("tasks/pushNotificationConfig/list"), @handler)

      assert response["error"]["code"] == -32_003
    end

    test "pushNotificationConfig/delete returns unsupported" do
      {:reply, response} =
        JSONRPC.handle(rpc("tasks/pushNotificationConfig/delete"), @handler)

      assert response["error"]["code"] == -32_003
    end
  end

  # -- tasks/pushNotificationConfig ------------------------------------------

  describe "push notification config dispatch" do
    test "set decodes the flat snake_case form the TCK sends" do
      params = %{
        "task_id" => "tsk-1",
        "id" => "pcfg-1",
        "url" => "https://example.com/hook",
        "authentication" => %{"scheme" => "Bearer", "credentials" => "s3cret"}
      }

      {:reply, response} =
        JSONRPC.handle(rpc("CreateTaskPushNotificationConfig", params), @push_handler)

      assert response["result"]["taskId"] == "tsk-1"
      assert response["result"]["id"] == "pcfg-1"
      assert response["result"]["url"] == "https://example.com/hook"

      assert response["result"]["authentication"] == %{
               "scheme" => "Bearer",
               "credentials" => "s3cret"
             }
    end

    test "set accepts the v0.3 nested form and plural auth schemes" do
      params = %{
        "taskId" => "tsk-1",
        "pushNotificationConfig" => %{
          "id" => "pcfg-1",
          "url" => "https://example.com/hook",
          "authentication" => %{"schemes" => ["Bearer"], "credentials" => "s3cret"}
        }
      }

      {:reply, response} =
        JSONRPC.handle(rpc("tasks/pushNotificationConfig/set", params), @push_handler)

      assert response["result"]["taskId"] == "tsk-1"
      assert response["result"]["id"] == "pcfg-1"
      assert response["result"]["authentication"]["scheme"] == "Bearer"
    end

    test "set passes a nil id through for the handler to fill" do
      params = %{"task_id" => "tsk-1", "url" => "https://example.com/hook"}

      {:reply, response} =
        JSONRPC.handle(rpc("tasks/pushNotificationConfig/set", params), @push_handler)

      assert response["result"]["id"] == "pcfg-generated"
    end

    test "set without a url is invalid params" do
      params = %{"task_id" => "tsk-1"}

      {:reply, response} =
        JSONRPC.handle(rpc("tasks/pushNotificationConfig/set", params), @push_handler)

      assert response["error"]["code"] == -32_602
    end

    test "get returns the stored config" do
      params = %{
        "task_id" => A2A.Test.PushHandler.known_task(),
        "id" => A2A.Test.PushHandler.known_config_id()
      }

      {:reply, response} =
        JSONRPC.handle(rpc("GetTaskPushNotificationConfig", params), @push_handler)

      assert response["result"]["id"] == A2A.Test.PushHandler.known_config_id()
      assert response["result"]["url"] == "https://example.com/hook"
    end

    test "get with an unknown config id returns TaskNotFoundError" do
      params = %{"task_id" => A2A.Test.PushHandler.known_task(), "id" => "pcfg-missing"}

      {:reply, response} =
        JSONRPC.handle(rpc("tasks/pushNotificationConfig/get", params), @push_handler)

      assert response["error"]["code"] == -32_001
    end

    test "list returns configs under the configs key" do
      params = %{"task_id" => A2A.Test.PushHandler.known_task()}

      {:reply, response} =
        JSONRPC.handle(rpc("ListTaskPushNotificationConfigs", params), @push_handler)

      assert [config] = response["result"]["configs"]
      assert config["id"] == A2A.Test.PushHandler.known_config_id()
    end

    test "list returns an empty list for a task with no configs" do
      params = %{"task_id" => "tsk-other"}

      {:reply, response} =
        JSONRPC.handle(rpc("tasks/pushNotificationConfig/list", params), @push_handler)

      assert response["result"]["configs"] == []
    end

    test "delete succeeds and repeating it stays successful" do
      params = %{
        "task_id" => A2A.Test.PushHandler.known_task(),
        "id" => A2A.Test.PushHandler.known_config_id()
      }

      request = rpc("DeleteTaskPushNotificationConfig", params)

      {:reply, first} = JSONRPC.handle(request, @push_handler)
      {:reply, second} = JSONRPC.handle(request, @push_handler)

      assert first["result"] == %{}
      assert second["result"] == %{}
      refute Map.has_key?(second, "error")
    end

    test "an unknown pushNotificationConfig sub-method is method_not_found" do
      {:reply, response} =
        JSONRPC.handle(rpc("tasks/pushNotificationConfig/purge"), @push_handler)

      assert response["error"]["code"] == -32_601
    end
  end

  describe "agent/getAuthenticatedExtendedCard" do
    test "returns unsupported_operation" do
      {:reply, response} =
        JSONRPC.handle(rpc("agent/getAuthenticatedExtendedCard"), @handler)

      assert response["error"]["code"] == -32_004
    end
  end

  # -- PascalCase method aliases ---------------------------------------------

  describe "PascalCase method aliases" do
    test "SendMessage dispatches as message/send" do
      {:reply, response} =
        JSONRPC.handle(rpc("SendMessage", message_params()), @handler)

      task = response["result"]["task"]
      assert is_binary(task["id"])
      assert task["status"]["state"] == "TASK_STATE_COMPLETED"
    end

    test "SendStreamingMessage dispatches as message/stream" do
      result = JSONRPC.handle(rpc("SendStreamingMessage", message_params()), @handler)

      assert {:stream, "message/stream", _params, 1} = result
    end

    test "GetTask dispatches as tasks/get" do
      {:reply, response} =
        JSONRPC.handle(rpc("GetTask", %{"id" => "existing"}), @handler)

      assert response["result"]["id"] == "existing"
    end

    test "CancelTask dispatches as tasks/cancel" do
      {:reply, response} =
        JSONRPC.handle(rpc("CancelTask", %{"id" => "cancelable"}), @handler)

      assert response["result"]["status"]["state"] == "TASK_STATE_CANCELED"
    end

    test "GetExtendedAgentCard returns unsupported_operation" do
      {:reply, response} =
        JSONRPC.handle(rpc("GetExtendedAgentCard"), @handler)

      assert response["error"]["code"] == -32_004
    end

    test "CreateTaskPushNotificationConfig returns push_notification_not_supported" do
      {:reply, response} =
        JSONRPC.handle(rpc("CreateTaskPushNotificationConfig"), @handler)

      assert response["error"]["code"] == -32_003
    end

    test "ListTasks returns method_not_found when handler lacks handle_list" do
      {:reply, response} = JSONRPC.handle(rpc("ListTasks"), @handler)

      assert response["error"]["code"] == -32_601
    end
  end

  # -- unknown method --------------------------------------------------------

  describe "unknown method" do
    test "returns method_not_found" do
      {:reply, response} = JSONRPC.handle(rpc("custom/unknown"), @handler)

      assert response["error"]["code"] == -32_601
      assert response["error"]["data"] == "custom/unknown"
    end
  end

  # -- envelope errors -------------------------------------------------------

  describe "envelope errors" do
    test "missing jsonrpc field" do
      {:reply, response} =
        JSONRPC.handle(%{"method" => "tasks/get", "id" => 1}, @handler)

      assert response["error"]["code"] == -32_600
      assert response["id"] == 1
    end

    test "missing method field" do
      {:reply, response} =
        JSONRPC.handle(%{"jsonrpc" => "2.0", "id" => 1}, @handler)

      assert response["error"]["code"] == -32_600
    end

    test "preserves id in error responses" do
      {:reply, response} =
        JSONRPC.handle(%{"jsonrpc" => "2.0", "id" => "req-1"}, @handler)

      assert response["id"] == "req-1"
    end

    test "nil id when no valid id present" do
      {:reply, response} = JSONRPC.handle(%{"jsonrpc" => "1.0"}, @handler)

      assert response["id"] == nil
    end
  end

  # -- handler exceptions ----------------------------------------------------

  describe "handler exceptions" do
    test "runtime errors are caught and returned as internal_error" do
      defmodule CrashingHandler do
        @moduledoc false
        @behaviour A2A.JSONRPC

        @impl true
        def handle_send(_message, _params, _ctx), do: raise("boom")

        @impl true
        def handle_get(_id, _params, _ctx), do: raise("boom")

        @impl true
        def handle_cancel(_id, _params, _ctx), do: raise("boom")
      end

      {:reply, response} =
        JSONRPC.handle(rpc("message/send", message_params()), CrashingHandler)

      assert response["error"]["code"] == -32_603
      assert response["error"]["data"] == "boom"
    end
  end
end
