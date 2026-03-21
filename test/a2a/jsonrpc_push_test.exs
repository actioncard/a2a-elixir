defmodule A2A.JSONRPC.PushTest do
  use ExUnit.Case, async: true

  alias A2A.JSONRPC

  @handler A2A.Test.PushHandler
  @no_push_handler A2A.Test.Handler

  defp rpc(method, params \\ %{}, id \\ 1) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  setup do
    store = A2A.Test.PushHandler.init_store()
    %{ctx: %{store: store}}
  end

  describe "handler without push callbacks" do
    test "CreateTaskPushNotificationConfig returns -32003" do
      {:reply, resp} =
        JSONRPC.handle(
          rpc("CreateTaskPushNotificationConfig", %{"url" => "https://x.com/h"}),
          @no_push_handler
        )

      assert resp["error"]["code"] == -32_003
    end

    test "GetTaskPushNotificationConfig returns -32003" do
      {:reply, resp} =
        JSONRPC.handle(
          rpc("GetTaskPushNotificationConfig", %{"taskId" => "t1", "id" => "c1"}),
          @no_push_handler
        )

      assert resp["error"]["code"] == -32_003
    end

    test "ListTaskPushNotificationConfigs returns -32003" do
      {:reply, resp} =
        JSONRPC.handle(
          rpc("ListTaskPushNotificationConfigs", %{"taskId" => "t1"}),
          @no_push_handler
        )

      assert resp["error"]["code"] == -32_003
    end

    test "DeleteTaskPushNotificationConfig returns -32003" do
      {:reply, resp} =
        JSONRPC.handle(
          rpc("DeleteTaskPushNotificationConfig", %{"taskId" => "t1", "id" => "c1"}),
          @no_push_handler
        )

      assert resp["error"]["code"] == -32_003
    end

    test "legacy slash-style set returns -32003" do
      {:reply, resp} =
        JSONRPC.handle(rpc("tasks/pushNotificationConfig/set"), @no_push_handler)

      assert resp["error"]["code"] == -32_003
    end

    test "legacy slash-style get returns -32003" do
      {:reply, resp} =
        JSONRPC.handle(rpc("tasks/pushNotificationConfig/get"), @no_push_handler)

      assert resp["error"]["code"] == -32_003
    end

    test "legacy slash-style list returns -32003" do
      {:reply, resp} =
        JSONRPC.handle(rpc("tasks/pushNotificationConfig/list"), @no_push_handler)

      assert resp["error"]["code"] == -32_003
    end

    test "legacy slash-style delete returns -32003" do
      {:reply, resp} =
        JSONRPC.handle(rpc("tasks/pushNotificationConfig/delete"), @no_push_handler)

      assert resp["error"]["code"] == -32_003
    end
  end

  describe "CreateTaskPushNotificationConfig" do
    test "creates config and returns it", %{ctx: ctx} do
      params = %{
        "taskId" => "tsk-1",
        "url" => "https://example.com/hook",
        "token" => "my-token",
        "authentication" => %{"scheme" => "Bearer", "credentials" => "secret"}
      }

      {:reply, resp} =
        JSONRPC.handle(rpc("CreateTaskPushNotificationConfig", params), @handler, ctx)

      assert resp["result"]["url"] == "https://example.com/hook"
      assert resp["result"]["taskId"] == "tsk-1"
      assert resp["result"]["id"]
    end

    test "preserves provided ID", %{ctx: ctx} do
      params = %{"id" => "my-id", "taskId" => "tsk-1", "url" => "https://x.com/h"}

      {:reply, resp} =
        JSONRPC.handle(rpc("CreateTaskPushNotificationConfig", params), @handler, ctx)

      assert resp["result"]["id"] == "my-id"
    end

    test "via legacy method name", %{ctx: ctx} do
      params = %{"taskId" => "tsk-1", "url" => "https://x.com/h"}

      {:reply, resp} =
        JSONRPC.handle(rpc("tasks/pushNotificationConfig/set", params), @handler, ctx)

      assert resp["result"]["url"] == "https://x.com/h"
    end
  end

  describe "GetTaskPushNotificationConfig" do
    test "retrieves a stored config", %{ctx: ctx} do
      create = %{"id" => "cfg-1", "taskId" => "tsk-1", "url" => "https://x.com/h"}

      {:reply, _} =
        JSONRPC.handle(rpc("CreateTaskPushNotificationConfig", create), @handler, ctx)

      {:reply, resp} =
        JSONRPC.handle(
          rpc("GetTaskPushNotificationConfig", %{"taskId" => "tsk-1", "id" => "cfg-1"}),
          @handler,
          ctx
        )

      assert resp["result"]["id"] == "cfg-1"
    end

    test "returns error for missing config", %{ctx: ctx} do
      {:reply, resp} =
        JSONRPC.handle(
          rpc("GetTaskPushNotificationConfig", %{"taskId" => "x", "id" => "y"}),
          @handler,
          ctx
        )

      assert resp["error"]["code"] == -32_001
    end
  end

  describe "ListTaskPushNotificationConfigs" do
    test "lists configs for a task", %{ctx: ctx} do
      for id <- ["cfg-1", "cfg-2"] do
        params = %{"id" => id, "taskId" => "tsk-list", "url" => "https://x.com/#{id}"}
        JSONRPC.handle(rpc("CreateTaskPushNotificationConfig", params), @handler, ctx)
      end

      {:reply, resp} =
        JSONRPC.handle(
          rpc("ListTaskPushNotificationConfigs", %{"taskId" => "tsk-list"}),
          @handler,
          ctx
        )

      configs = resp["result"]["configs"]
      assert length(configs) == 2
    end

    test "returns empty list for unknown task", %{ctx: ctx} do
      {:reply, resp} =
        JSONRPC.handle(
          rpc("ListTaskPushNotificationConfigs", %{"taskId" => "tsk-none"}),
          @handler,
          ctx
        )

      assert resp["result"]["configs"] == []
    end
  end

  describe "DeleteTaskPushNotificationConfig" do
    test "deletes a config", %{ctx: ctx} do
      create = %{"id" => "cfg-del", "taskId" => "tsk-del", "url" => "https://x.com/h"}
      JSONRPC.handle(rpc("CreateTaskPushNotificationConfig", create), @handler, ctx)

      {:reply, resp} =
        JSONRPC.handle(
          rpc("DeleteTaskPushNotificationConfig", %{"taskId" => "tsk-del", "id" => "cfg-del"}),
          @handler,
          ctx
        )

      assert resp["result"] == %{}

      {:reply, get_resp} =
        JSONRPC.handle(
          rpc("GetTaskPushNotificationConfig", %{"taskId" => "tsk-del", "id" => "cfg-del"}),
          @handler,
          ctx
        )

      assert get_resp["error"]["code"] == -32_001
    end

    test "returns error for missing config", %{ctx: ctx} do
      {:reply, resp} =
        JSONRPC.handle(
          rpc("DeleteTaskPushNotificationConfig", %{"taskId" => "x", "id" => "y"}),
          @handler,
          ctx
        )

      assert resp["error"]["code"] == -32_001
    end
  end
end
