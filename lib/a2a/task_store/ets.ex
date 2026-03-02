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

  @impl A2A.TaskStore
  def get(table, task_id) do
    case :ets.lookup(table, task_id) do
      [{^task_id, task}] -> {:ok, task}
      [] -> {:error, :not_found}
    end
  end

  @impl A2A.TaskStore
  def put(table, %A2A.Task{} = task) do
    :ets.insert(table, {task.id, task})
    :ok
  end

  @impl A2A.TaskStore
  def delete(table, task_id) do
    :ets.delete(table, task_id)
    :ok
  end

  @impl A2A.TaskStore
  def list(table, context_id) do
    tasks =
      :ets.tab2list(table)
      |> Enum.filter(fn {_id, task} -> task.context_id == context_id end)
      |> Enum.map(fn {_id, task} -> task end)

    {:ok, tasks}
  end

  @impl A2A.TaskStore
  def list_all(table, opts \\ []) do
    context_id = Keyword.get(opts, :context_id)
    status_filter = Keyword.get(opts, :status)
    timestamp_after = Keyword.get(opts, :status_timestamp_after)
    page_size = Keyword.get(opts, :page_size, 50)
    page_token = Keyword.get(opts, :page_token)
    history_length = Keyword.get(opts, :history_length, 0)
    include_artifacts = Keyword.get(opts, :include_artifacts, false)

    all_tasks =
      :ets.tab2list(table)
      |> Enum.map(fn {_id, task} -> task end)
      |> Enum.sort_by(& &1.id)

    filtered =
      all_tasks
      |> maybe_filter_context(context_id)
      |> maybe_filter_status(status_filter)
      |> maybe_filter_timestamp(timestamp_after)

    total_size = length(filtered)

    # Pagination: page_token is the task ID to start after
    filtered =
      case page_token do
        nil ->
          filtered

        token ->
          filtered
          |> Enum.drop_while(fn task -> task.id <= token end)
      end

    page = Enum.take(filtered, page_size)

    next_token =
      if length(filtered) > page_size do
        page |> List.last() |> Map.get(:id)
      else
        ""
      end

    tasks =
      Enum.map(page, fn task ->
        task
        |> maybe_limit_history(history_length)
        |> maybe_strip_artifacts(include_artifacts)
      end)

    {:ok,
     %{
       tasks: tasks,
       total_size: total_size,
       page_size: page_size,
       next_page_token: next_token
     }}
  end

  defp maybe_filter_context(tasks, nil), do: tasks

  defp maybe_filter_context(tasks, ctx_id) do
    Enum.filter(tasks, fn task -> task.context_id == ctx_id end)
  end

  defp maybe_filter_status(tasks, nil), do: tasks

  defp maybe_filter_status(tasks, status) do
    Enum.filter(tasks, fn task -> task.status.state == status end)
  end

  defp maybe_filter_timestamp(tasks, nil), do: tasks

  defp maybe_filter_timestamp(tasks, after_dt) do
    Enum.filter(tasks, fn task ->
      task.status.timestamp != nil and
        DateTime.compare(task.status.timestamp, after_dt) == :gt
    end)
  end

  defp maybe_limit_history(task, 0), do: %{task | history: []}

  defp maybe_limit_history(task, n) when is_integer(n) and n > 0 do
    %{task | history: Enum.take(task.history, -n)}
  end

  defp maybe_limit_history(task, _), do: task

  defp maybe_strip_artifacts(task, true), do: task
  defp maybe_strip_artifacts(task, _), do: %{task | artifacts: []}

  # --- GenServer callbacks ---

  @impl GenServer
  def init(name) do
    table = :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end
end
