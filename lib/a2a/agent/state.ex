defmodule A2A.Agent.State do
  @moduledoc false

  @type push_key :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          module: module(),
          tasks: %{String.t() => A2A.Task.t()},
          contexts: %{String.t() => [String.t()]},
          push_configs: %{push_key() => A2A.PushNotificationConfig.t()},
          task_store: {module(), A2A.TaskStore.ref()} | nil
        }

  defstruct module: nil,
            tasks: %{},
            contexts: %{},
            push_configs: %{},
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
    if exports?(mod, :list_all, 2) do
      mod.list_all(ref, params_to_list_opts(params))
    else
      list_from_memory(state, params)
    end
  end

  def list_tasks(state, params) do
    list_from_memory(state, params)
  end

  @doc """
  Stores a push notification config.

  Uses the external store when it implements the push callbacks, the in-memory
  map otherwise — one or the other, never both. A store may be shared between
  agents, so caching configs alongside it would let one agent's stale copy
  shadow another's delete and keep a removed webhook alive.
  """
  @spec put_push_config(t(), A2A.PushNotificationConfig.t()) ::
          {t(), {:ok, A2A.PushNotificationConfig.t()} | {:error, term()}}
  def put_push_config(%{task_store: {mod, ref}} = state, config) do
    if exports?(mod, :set_push_config, 2) do
      {state, mod.set_push_config(ref, config)}
    else
      put_push_config_in_memory(state, config)
    end
  end

  def put_push_config(state, config), do: put_push_config_in_memory(state, config)

  @doc """
  Retrieves a push notification config by task ID and config ID.
  """
  @spec get_push_config(t(), String.t(), String.t()) ::
          {:ok, A2A.PushNotificationConfig.t()} | {:error, :not_found}
  def get_push_config(%{task_store: {mod, ref}} = state, task_id, config_id) do
    if exports?(mod, :get_push_config, 3) do
      mod.get_push_config(ref, task_id, config_id)
    else
      get_push_config_in_memory(state, task_id, config_id)
    end
  end

  def get_push_config(state, task_id, config_id) do
    get_push_config_in_memory(state, task_id, config_id)
  end

  @doc """
  Lists every push notification config registered for a task.
  """
  @spec list_push_configs(t(), String.t()) :: {:ok, [A2A.PushNotificationConfig.t()]}
  def list_push_configs(%{task_store: {mod, ref}} = state, task_id) do
    if exports?(mod, :list_push_configs, 2) do
      mod.list_push_configs(ref, task_id)
    else
      list_push_configs_in_memory(state, task_id)
    end
  end

  def list_push_configs(state, task_id), do: list_push_configs_in_memory(state, task_id)

  @doc """
  Deletes a push notification config. Idempotent.
  """
  @spec delete_push_config(t(), String.t(), String.t()) :: {t(), :ok}
  def delete_push_config(%{task_store: {mod, ref}} = state, task_id, config_id) do
    if exports?(mod, :delete_push_config, 3) do
      {state, mod.delete_push_config(ref, task_id, config_id)}
    else
      delete_push_config_in_memory(state, task_id, config_id)
    end
  end

  def delete_push_config(state, task_id, config_id) do
    delete_push_config_in_memory(state, task_id, config_id)
  end

  defp put_push_config_in_memory(state, config) do
    key = {config.task_id, config.id}
    {%{state | push_configs: Map.put(state.push_configs, key, config)}, {:ok, config}}
  end

  defp get_push_config_in_memory(state, task_id, config_id) do
    case Map.fetch(state.push_configs, {task_id, config_id}) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, :not_found}
    end
  end

  defp list_push_configs_in_memory(state, task_id) do
    configs =
      state.push_configs
      |> Enum.filter(fn {{tid, _config_id}, _config} -> tid == task_id end)
      |> Enum.map(fn {_key, config} -> config end)

    {:ok, configs}
  end

  defp delete_push_config_in_memory(state, task_id, config_id) do
    {%{state | push_configs: Map.delete(state.push_configs, {task_id, config_id})}, :ok}
  end

  # See the note on `A2A.JSONRPC.exports?/3`: an unloaded store module would
  # otherwise read as one that implements no optional callbacks.
  defp exports?(mod, fun, arity) do
    Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
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
