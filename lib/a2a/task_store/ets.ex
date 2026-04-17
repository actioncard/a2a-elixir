defmodule A2A.TaskStore.ETS do
  @moduledoc """
  ETS-backed task store implementation.

  Uses a named ETS table for storage. The store reference is the table name atom.
  Suitable for single-node, concurrent access.

  ## Usage

      {:ok, _pid} = A2A.TaskStore.ETS.start_link(name: :my_tasks)
      :ok = A2A.TaskStore.ETS.put(:my_tasks, task)
      {:ok, task} = A2A.TaskStore.ETS.get(:my_tasks, "tsk-abc123")

  ## With an Agent

      MyAgent.start_link(task_store: {A2A.TaskStore.ETS, :my_tasks})

  ## Multi-Tenant Usage

  For tenant-isolated storage, use `tenant_ref/2` to create a namespaced
  reference. Tasks stored under one tenant are invisible to other tenants.

      ref = A2A.TaskStore.ETS.tenant_ref(:my_tasks, "acme")
      :ok = A2A.TaskStore.ETS.put(ref, task)

      # Only returns tasks for "acme" tenant
      {:ok, tasks} = A2A.TaskStore.ETS.list_all(ref)

      # Plain ref still works (backward compatible)
      {:ok, all} = A2A.TaskStore.ETS.list_all(:my_tasks)
  """

  use GenServer

  @behaviour A2A.TaskStore

  @doc """
  Starts the ETS task store process which creates the underlying table.

  ## Options

  - `:name` — the table/process name (required)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @doc """
  Creates a tenant-namespaced store reference.

  All operations using this ref will scope keys by the given tenant,
  providing task isolation between tenants sharing the same ETS table.

      ref = A2A.TaskStore.ETS.tenant_ref(:my_tasks, "acme")
      :ok = A2A.TaskStore.ETS.put(ref, task)
  """
  @spec tenant_ref(atom(), String.t()) :: {atom(), String.t()}
  def tenant_ref(table, tenant) when is_atom(table) and is_binary(tenant) do
    {table, tenant}
  end

  # -- get ---------------------------------------------------------------------

  @doc false
  def get({table, tenant}, task_id) do
    key = {tenant, task_id}

    case :ets.lookup(table, key) do
      [{^key, task}] -> {:ok, task}
      [] -> {:error, :not_found}
    end
  end

  @impl A2A.TaskStore
  def get(table, task_id) do
    case :ets.lookup(table, task_id) do
      [{^task_id, task}] -> {:ok, task}
      [] -> {:error, :not_found}
    end
  end

  # -- put ---------------------------------------------------------------------

  @doc false
  def put({table, tenant}, %A2A.Task{} = task) do
    :ets.insert(table, {{tenant, task.id}, task})
    :ok
  end

  @impl A2A.TaskStore
  def put(table, %A2A.Task{} = task) do
    :ets.insert(table, {task.id, task})
    :ok
  end

  # -- delete ------------------------------------------------------------------

  @doc false
  def delete({table, tenant}, task_id) do
    :ets.delete(table, {tenant, task_id})
    :ok
  end

  @impl A2A.TaskStore
  def delete(table, task_id) do
    :ets.delete(table, task_id)
    :ok
  end

  # -- list --------------------------------------------------------------------

  @doc false
  def list({table, tenant}, context_id) do
    :ets.tab2list(table)
    |> Enum.filter(fn
      {{^tenant, _id}, task} -> task.context_id == context_id
      _ -> false
    end)
    |> Enum.map(fn {_key, task} -> task end)
    |> then(&{:ok, &1})
  end

  @impl A2A.TaskStore
  def list(table, context_id) do
    :ets.tab2list(table)
    |> Enum.filter(fn
      {{_tenant, _id}, _task} -> false
      {_id, task} -> task.context_id == context_id
    end)
    |> Enum.map(fn {_key, task} -> task end)
    |> then(&{:ok, &1})
  end

  # -- list_all ----------------------------------------------------------------

  @doc false
  def list_all(ref, opts \\ [])

  def list_all({table, tenant}, opts) do
    :ets.tab2list(table)
    |> Enum.filter(fn
      {{^tenant, _id}, _task} -> true
      _ -> false
    end)
    |> Enum.map(fn {_key, task} -> task end)
    |> A2A.Task.Filter.apply(opts)
  end

  @impl A2A.TaskStore
  def list_all(table, opts) do
    :ets.tab2list(table)
    |> Enum.filter(fn
      {{_tenant, _id}, _task} -> false
      _ -> true
    end)
    |> Enum.map(fn {_key, task} -> task end)
    |> A2A.Task.Filter.apply(opts)
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(name) do
    table = :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end
end
