defmodule A2A.TaskStore.PushConfigTest do
  use ExUnit.Case, async: true

  alias A2A.PushNotificationConfig
  alias A2A.Task
  alias A2A.TaskStore.ETS

  setup do
    table = :"push_store_#{System.unique_integer([:positive])}"
    start_supervised!({ETS, name: table})
    %{table: table}
  end

  defp config(task_id, id, url \\ "https://example.com/hook") do
    %PushNotificationConfig{id: id, task_id: task_id, url: url}
  end

  describe "set_push_config/2 and get_push_config/3" do
    test "stores and retrieves a config", %{table: table} do
      config = config("tsk-1", "pcfg-1")

      assert {:ok, ^config} = ETS.set_push_config(table, config)
      assert {:ok, ^config} = ETS.get_push_config(table, "tsk-1", "pcfg-1")
    end

    test "replaces a config carrying the same id", %{table: table} do
      ETS.set_push_config(table, config("tsk-1", "pcfg-1"))
      updated = config("tsk-1", "pcfg-1", "https://example.com/other")
      ETS.set_push_config(table, updated)

      assert {:ok, ^updated} = ETS.get_push_config(table, "tsk-1", "pcfg-1")
    end

    test "returns :not_found for an unknown config id", %{table: table} do
      assert {:error, :not_found} = ETS.get_push_config(table, "tsk-1", "pcfg-missing")
    end

    test "scopes config ids to their task", %{table: table} do
      ETS.set_push_config(table, config("tsk-1", "pcfg-1"))

      assert {:error, :not_found} = ETS.get_push_config(table, "tsk-2", "pcfg-1")
    end
  end

  describe "list_push_configs/2" do
    test "returns only the configs of the given task", %{table: table} do
      ETS.set_push_config(table, config("tsk-1", "pcfg-1"))
      ETS.set_push_config(table, config("tsk-1", "pcfg-2"))
      ETS.set_push_config(table, config("tsk-2", "pcfg-3"))

      assert {:ok, configs} = ETS.list_push_configs(table, "tsk-1")
      assert configs |> Enum.map(& &1.id) |> Enum.sort() == ["pcfg-1", "pcfg-2"]
    end

    test "returns an empty list for a task with no configs", %{table: table} do
      assert {:ok, []} = ETS.list_push_configs(table, "tsk-none")
    end
  end

  describe "delete_push_config/3" do
    test "removes the config", %{table: table} do
      ETS.set_push_config(table, config("tsk-1", "pcfg-1"))

      assert :ok = ETS.delete_push_config(table, "tsk-1", "pcfg-1")
      assert {:error, :not_found} = ETS.get_push_config(table, "tsk-1", "pcfg-1")
    end

    test "deleting a config that is not there still succeeds", %{table: table} do
      assert :ok = ETS.delete_push_config(table, "tsk-1", "pcfg-missing")
      assert :ok = ETS.delete_push_config(table, "tsk-1", "pcfg-missing")
    end
  end

  # Configs live in their own table precisely so they cannot reach the task
  # read paths, all three of which treat every row they see as a task.
  describe "isolation from the task table" do
    test "a stored config leaves list_all/2 working", %{table: table} do
      ETS.put(table, Task.new(id: "tsk-1"))
      ETS.set_push_config(table, config("tsk-1", "pcfg-1"))

      assert {:ok, %{tasks: [task]}} = ETS.list_all(table)
      assert task.id == "tsk-1"
    end

    test "a stored config leaves list/2 working", %{table: table} do
      ETS.put(table, Task.new(id: "tsk-1", context_id: "ctx-1"))
      ETS.set_push_config(table, config("tsk-1", "pcfg-1"))

      assert {:ok, [task]} = ETS.list(table, "ctx-1")
      assert task.id == "tsk-1"
    end

    test "a stored config leaves get/2 working", %{table: table} do
      task = Task.new(id: "tsk-1")
      ETS.put(table, task)
      ETS.set_push_config(table, config("tsk-1", "pcfg-1"))

      assert {:ok, ^task} = ETS.get(table, "tsk-1")
    end
  end
end
