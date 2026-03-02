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
    %{task | status: A2A.Task.Status.new(new_state, message)}
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
    |> encode_list_result()
  end

  def list_tasks(state, params) do
    list_from_memory(state, params)
    |> encode_list_result()
  end

  defp list_from_memory(state, params) do
    page_size = params["pageSize"] || 50
    page_token = params["pageToken"]
    context_id = params["contextId"]
    status_str = params["status"]
    history_length = params["historyLength"] || 0
    include_artifacts = params["includeArtifacts"] || false
    timestamp_after_str = params["statusTimestampAfter"]

    status_atom =
      case status_str do
        nil -> nil
        s -> decode_state_atom(s)
      end

    timestamp_after =
      case timestamp_after_str do
        nil -> nil
        s -> parse_datetime(s)
      end

    all_tasks =
      state.tasks
      |> Map.values()
      |> Enum.sort_by(& &1.id)

    filtered =
      all_tasks
      |> maybe_filter(&(&1.context_id == context_id), context_id)
      |> maybe_filter(&(&1.status.state == status_atom), status_atom)
      |> maybe_filter_ts(timestamp_after)

    total_size = length(filtered)

    filtered =
      case page_token do
        nil -> filtered
        "" -> filtered
        token -> Enum.drop_while(filtered, fn t -> t.id <= token end)
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
        |> limit_history(history_length)
        |> strip_artifacts(include_artifacts)
      end)

    {:ok,
     %{
       tasks: tasks,
       total_size: total_size,
       page_size: page_size,
       next_page_token: next_token
     }}
  end

  defp maybe_filter(tasks, _fun, nil), do: tasks
  defp maybe_filter(tasks, fun, _val), do: Enum.filter(tasks, fun)

  defp maybe_filter_ts(tasks, nil), do: tasks

  defp maybe_filter_ts(tasks, after_dt) do
    Enum.filter(tasks, fn task ->
      task.status.timestamp != nil and
        DateTime.compare(task.status.timestamp, after_dt) == :gt
    end)
  end

  defp limit_history(task, 0), do: %{task | history: []}
  defp limit_history(task, n) when is_integer(n) and n > 0 do
    %{task | history: Enum.take(task.history, -n)}
  end
  defp limit_history(task, _), do: task

  defp strip_artifacts(task, true), do: task
  defp strip_artifacts(task, _), do: %{task | artifacts: []}

  defp decode_state_atom("TASK_STATE_SUBMITTED"), do: :submitted
  defp decode_state_atom("TASK_STATE_WORKING"), do: :working
  defp decode_state_atom("TASK_STATE_INPUT_REQUIRED"), do: :input_required
  defp decode_state_atom("TASK_STATE_COMPLETED"), do: :completed
  defp decode_state_atom("TASK_STATE_CANCELED"), do: :canceled
  defp decode_state_atom("TASK_STATE_FAILED"), do: :failed
  defp decode_state_atom("TASK_STATE_REJECTED"), do: :rejected
  defp decode_state_atom("TASK_STATE_AUTH_REQUIRED"), do: :auth_required
  defp decode_state_atom("TASK_STATE_UNKNOWN"), do: :unknown
  defp decode_state_atom(s), do: String.to_existing_atom(s)

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
        s -> decode_state_atom(s)
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

  defp encode_list_result({:ok, %{tasks: tasks} = result}) do
    encoded_tasks = Enum.map(tasks, fn task ->
      {:ok, encoded} = A2A.JSON.encode(task)
      encoded
    end)

    {:ok,
     %{
       "tasks" => encoded_tasks,
       "totalSize" => result.total_size,
       "pageSize" => result.page_size,
       "nextPageToken" => result.next_page_token
     }}
  end

  defp encode_list_result(error), do: error
end
