defmodule A2A.Agent.State do
  @moduledoc false

  @type t :: %__MODULE__{
          module: module(),
          tasks: %{String.t() => A2A.Task.t()},
          contexts: %{String.t() => [String.t()]},
          task_store: {module(), A2A.TaskStore.ref()} | nil
        }

  defstruct module: nil,
            tasks: %{},
            contexts: %{},
            task_store: nil

  @doc """
  Transitions a task to a new state, updating the status.
  """
  @spec transition(A2A.Task.t(), A2A.Task.Status.state(), A2A.Message.t() | nil) ::
          A2A.Task.t()
  def transition(task, new_state, message \\ nil) do
    old_state = if task.status, do: task.status.state
    task = %{task | status: A2A.Task.Status.new(new_state, message)}

    :telemetry.execute(
      [:a2a, :task, :transition],
      %{system_time: System.system_time()},
      %{
        task_id: task.id,
        context_id: task.context_id,
        from: old_state,
        to: new_state
      }
    )

    task
  end

  @doc """
  Stores a task in the internal state map and optionally in the external store.
  """
  @spec put_task(t(), A2A.Task.t()) :: t()
  def put_task(%{task_store: {mod, ref}} = state, task) do
    mod.put(ref, task)
    %{state | tasks: Map.put(state.tasks, task.id, task)}
  end

  def put_task(state, task) do
    %{state | tasks: Map.put(state.tasks, task.id, task)}
  end

  @doc """
  Retrieves a task, checking the external store first if configured.
  """
  @spec get_task(t(), String.t()) :: {:ok, A2A.Task.t()} | {:error, :not_found}
  def get_task(%{task_store: {mod, ref}} = state, task_id) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, task} -> {:ok, task}
      :error -> mod.get(ref, task_id)
    end
  end

  def get_task(state, task_id) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, task} -> {:ok, task}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Tracks a task under its context_id.
  """
  @spec track_context(t(), A2A.Task.t()) :: t()
  def track_context(state, %{context_id: nil}), do: state

  def track_context(state, %{context_id: ctx_id, id: task_id}) do
    contexts = Map.update(state.contexts, ctx_id, [task_id], &[task_id | &1])
    %{state | contexts: contexts}
  end

  @doc """
  Lists tasks with filtering/pagination. Delegates to external store if
  it supports `list_all/2`, otherwise uses the in-memory task map.
  """
  @spec list_tasks(t(), map()) :: {:ok, map()}
  def list_tasks(%{task_store: {mod, ref}} = state, params) do
    if function_exported?(mod, :list_all, 2) do
      mod.list_all(ref, params_to_list_opts(params))
    else
      list_from_memory(state, params)
    end
  end

  def list_tasks(state, params) do
    list_from_memory(state, params)
  end

  defp list_from_memory(state, params) do
    state.tasks
    |> Map.values()
    |> A2A.Task.Filter.apply(params_to_list_opts(params))
  end

  defp decode_state(str) do
    case A2A.JSON.decode_state(str) do
      {:ok, atom} -> atom
      {:error, _} -> :unknown
    end
  end

  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp params_to_list_opts(params) do
    status_atom =
      case params["status"] do
        nil -> nil
        s -> decode_state(s)
      end

    timestamp_after =
      case params["statusTimestampAfter"] do
        nil -> nil
        s -> parse_datetime(s)
      end

    [
      context_id: params["contextId"],
      status: status_atom,
      status_timestamp_after: timestamp_after,
      page_size: params["pageSize"] || 50,
      page_token: params["pageToken"],
      history_length: params["historyLength"] || 0,
      include_artifacts: params["includeArtifacts"] || false
    ]
  end
end
