defmodule A2A.TaskStore.PushConfigTest do
  use ExUnit.Case, async: true

  alias A2A.TaskStore.ETS
  alias A2A.PushNotificationConfig
  alias A2A.AuthenticationInfo

  setup do
    name = :"push_config_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ETS.start_link(name: name)
    %{store: name}
  end

  defp make_config(task_id, id, url \\ "https://example.com/hook") do
    %PushNotificationConfig{
      id: id,
      task_id: task_id,
      url: url,
      token: "tok-#{id}",
      authentication: %AuthenticationInfo{scheme: "Bearer", credentials: "cred-#{id}"}
    }
  end

  describe "set_push_config/2" do
    test "stores a config", %{store: store} do
      config = make_config("tsk-1", "cfg-1")
      assert {:ok, ^config} = ETS.set_push_config(store, config)
    end

    test "overwrites existing config", %{store: store} do
      {:ok, _} = ETS.set_push_config(store, make_config("tsk-1", "cfg-1", "https://first.com"))

      {:ok, result} =
        ETS.set_push_config(store, make_config("tsk-1", "cfg-1", "https://second.com"))

      assert result.url == "https://second.com"
    end
  end

  describe "get_push_config/3" do
    test "retrieves a stored config", %{store: store} do
      config = make_config("tsk-1", "cfg-1")
      {:ok, _} = ETS.set_push_config(store, config)
      assert {:ok, ^config} = ETS.get_push_config(store, "tsk-1", "cfg-1")
    end

    test "returns error for missing config", %{store: store} do
      assert {:error, :not_found} = ETS.get_push_config(store, "tsk-1", "cfg-missing")
    end

    test "configs are isolated by task_id", %{store: store} do
      {:ok, _} = ETS.set_push_config(store, make_config("tsk-1", "cfg-1"))
      {:ok, _} = ETS.set_push_config(store, make_config("tsk-2", "cfg-1"))
      {:ok, result} = ETS.get_push_config(store, "tsk-1", "cfg-1")
      assert result.task_id == "tsk-1"
    end
  end

  describe "list_push_configs/2" do
    test "lists configs for a task", %{store: store} do
      {:ok, _} = ETS.set_push_config(store, make_config("tsk-1", "cfg-1"))
      {:ok, _} = ETS.set_push_config(store, make_config("tsk-1", "cfg-2"))
      {:ok, _} = ETS.set_push_config(store, make_config("tsk-2", "cfg-3"))
      {:ok, configs} = ETS.list_push_configs(store, "tsk-1")
      assert length(configs) == 2
    end

    test "returns empty list for unknown task", %{store: store} do
      assert {:ok, []} = ETS.list_push_configs(store, "tsk-nonexistent")
    end
  end

  describe "delete_push_config/3" do
    test "deletes an existing config", %{store: store} do
      {:ok, _} = ETS.set_push_config(store, make_config("tsk-1", "cfg-1"))
      assert :ok = ETS.delete_push_config(store, "tsk-1", "cfg-1")
      assert {:error, :not_found} = ETS.get_push_config(store, "tsk-1", "cfg-1")
    end

    test "returns error for missing config", %{store: store} do
      assert {:error, :not_found} = ETS.delete_push_config(store, "tsk-1", "cfg-missing")
    end

    test "does not affect other configs", %{store: store} do
      {:ok, _} = ETS.set_push_config(store, make_config("tsk-1", "cfg-1"))
      {:ok, _} = ETS.set_push_config(store, make_config("tsk-1", "cfg-2"))
      :ok = ETS.delete_push_config(store, "tsk-1", "cfg-1")
      assert {:error, :not_found} = ETS.get_push_config(store, "tsk-1", "cfg-1")
      assert {:ok, _} = ETS.get_push_config(store, "tsk-1", "cfg-2")
    end
  end
end
