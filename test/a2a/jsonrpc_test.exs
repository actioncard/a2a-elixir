defmodule A2A.JSONRPCTest do
  use ExUnit.Case, async: true

  alias A2A.JSONRPC

  @handler A2A.Test.Handler

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
      assert task["kind"] == "task"
      assert task["status"]["state"] == "TASK_STATE_COMPLETED"
      assert [%{"kind" => "message"}] = task["history"]
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

  describe "push notification methods" do
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

      assert response["result"]["task"]["kind"] == "task"
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

    test "SubscribeToTask dispatches as tasks/resubscribe stream" do
      params = %{"id" => "tsk-1"}
      result = JSONRPC.handle(rpc("SubscribeToTask", params), @handler)

      assert {:stream, "tasks/resubscribe", ^params, 1} = result
    end

    test "GetTaskPushNotificationConfig returns push_notification_not_supported" do
      {:reply, response} =
        JSONRPC.handle(rpc("GetTaskPushNotificationConfig"), @handler)

      assert response["error"]["code"] == -32_003
    end

    test "ListTaskPushNotificationConfigs returns push_notification_not_supported" do
      {:reply, response} =
        JSONRPC.handle(rpc("ListTaskPushNotificationConfigs"), @handler)

      assert response["error"]["code"] == -32_003
    end

    test "DeleteTaskPushNotificationConfig returns push_notification_not_supported" do
      {:reply, response} =
        JSONRPC.handle(rpc("DeleteTaskPushNotificationConfig"), @handler)

      assert response["error"]["code"] == -32_003
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
