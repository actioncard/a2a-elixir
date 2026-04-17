defmodule A2A.TaskStore.ETSTenantTest do
  use ExUnit.Case, async: true

  alias A2A.TaskStore.ETS

  defp make_task(id, context_id \\ nil) do
    %A2A.Task{
      id: id,
      context_id: context_id,
      status: A2A.Task.Status.new(:completed),
      history: [],
      artifacts: [],
      metadata: %{}
    }
  end

  setup do
    table = :"tenant_test_#{System.unique_integer([:positive])}"
    start_supervised!({ETS, name: table})
    {:ok, table: table}
  end

  describe "tenant_ref/2" do
    test "creates a {table, tenant} tuple", %{table: table} do
      ref = ETS.tenant_ref(table, "acme")
      assert ref == {table, "acme"}
    end
  end

  describe "tenant-namespaced operations" do
    test "put and get with tenant ref", %{table: table} do
      ref = ETS.tenant_ref(table, "acme")
      task = make_task("tsk-1")

      assert :ok = ETS.put(ref, task)
      assert {:ok, ^task} = ETS.get(ref, "tsk-1")
    end

    test "tenant A tasks invisible to tenant B", %{table: table} do
      ref_a = ETS.tenant_ref(table, "acme")
      ref_b = ETS.tenant_ref(table, "beta")

      task_a = make_task("tsk-a")
      task_b = make_task("tsk-b")

      :ok = ETS.put(ref_a, task_a)
      :ok = ETS.put(ref_b, task_b)

      assert {:ok, ^task_a} = ETS.get(ref_a, "tsk-a")
      assert {:error, :not_found} = ETS.get(ref_a, "tsk-b")

      assert {:ok, ^task_b} = ETS.get(ref_b, "tsk-b")
      assert {:error, :not_found} = ETS.get(ref_b, "tsk-a")
    end

    test "tenant tasks invisible to plain ref", %{table: table} do
      ref = ETS.tenant_ref(table, "acme")
      task = make_task("tsk-1")
      :ok = ETS.put(ref, task)

      assert {:error, :not_found} = ETS.get(table, "tsk-1")
    end

    test "plain tasks invisible to tenant ref", %{table: table} do
      task = make_task("tsk-plain")
      :ok = ETS.put(table, task)

      ref = ETS.tenant_ref(table, "acme")
      assert {:error, :not_found} = ETS.get(ref, "tsk-plain")
    end

    test "delete only affects correct tenant", %{table: table} do
      ref_a = ETS.tenant_ref(table, "acme")
      ref_b = ETS.tenant_ref(table, "beta")

      :ok = ETS.put(ref_a, make_task("tsk-shared-id"))
      :ok = ETS.put(ref_b, make_task("tsk-shared-id"))

      :ok = ETS.delete(ref_a, "tsk-shared-id")

      assert {:error, :not_found} = ETS.get(ref_a, "tsk-shared-id")
      assert {:ok, _} = ETS.get(ref_b, "tsk-shared-id")
    end

    test "list by context_id is tenant-scoped", %{table: table} do
      ref_a = ETS.tenant_ref(table, "acme")
      ref_b = ETS.tenant_ref(table, "beta")

      :ok = ETS.put(ref_a, make_task("tsk-a1", "ctx-1"))
      :ok = ETS.put(ref_a, make_task("tsk-a2", "ctx-1"))
      :ok = ETS.put(ref_b, make_task("tsk-b1", "ctx-1"))

      {:ok, tasks} = ETS.list(ref_a, "ctx-1")
      ids = Enum.map(tasks, & &1.id) |> Enum.sort()
      assert ids == ["tsk-a1", "tsk-a2"]
    end

    test "list_all is tenant-scoped", %{table: table} do
      ref_a = ETS.tenant_ref(table, "acme")
      ref_b = ETS.tenant_ref(table, "beta")

      :ok = ETS.put(ref_a, make_task("tsk-a1"))
      :ok = ETS.put(ref_a, make_task("tsk-a2"))
      :ok = ETS.put(ref_b, make_task("tsk-b1"))
      :ok = ETS.put(table, make_task("tsk-plain"))

      {:ok, result} = ETS.list_all(ref_a, [])
      ids = Enum.map(result.tasks, & &1.id) |> Enum.sort()
      assert ids == ["tsk-a1", "tsk-a2"]
    end

    test "plain list excludes tenant tasks", %{table: table} do
      ref = ETS.tenant_ref(table, "acme")
      :ok = ETS.put(ref, make_task("tsk-tenant", "ctx-1"))
      :ok = ETS.put(table, make_task("tsk-plain", "ctx-1"))

      {:ok, tasks} = ETS.list(table, "ctx-1")
      ids = Enum.map(tasks, & &1.id)
      assert ids == ["tsk-plain"]
    end

    test "plain list_all excludes tenant tasks", %{table: table} do
      ref = ETS.tenant_ref(table, "acme")
      :ok = ETS.put(ref, make_task("tsk-tenant"))
      :ok = ETS.put(table, make_task("tsk-plain"))

      {:ok, result} = ETS.list_all(table, [])
      ids = Enum.map(result.tasks, & &1.id)
      assert ids == ["tsk-plain"]
    end
  end

  describe "backward compatibility" do
    test "existing non-tenant operations unchanged", %{table: table} do
      task = make_task("tsk-1", "ctx-1")

      assert :ok = ETS.put(table, task)
      assert {:ok, ^task} = ETS.get(table, "tsk-1")
      assert {:ok, [^task]} = ETS.list(table, "ctx-1")

      assert :ok = ETS.delete(table, "tsk-1")
      assert {:error, :not_found} = ETS.get(table, "tsk-1")
    end
  end
end
