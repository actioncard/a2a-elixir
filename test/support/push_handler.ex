defmodule A2A.Test.PushHandler do
  @moduledoc false
  @behaviour A2A.JSONRPC

  alias A2A.JSONRPC.Error

  def init_store do
    name = :"push_handler_#{System.unique_integer([:positive])}"
    :ets.new(name, [:named_table, :public, :set])
    name
  end

  @impl true
  def handle_send(message, _params, _context) do
    task = %A2A.Task{
      id: A2A.ID.generate("tsk"),
      status: A2A.Task.Status.new(:completed),
      history: [message]
    }

    {:ok, task}
  end

  @impl true
  def handle_get(task_id, _params, _context) do
    {:ok, %A2A.Task{id: task_id, status: A2A.Task.Status.new(:working)}}
  end

  @impl true
  def handle_cancel(task_id, _params, _context) do
    {:ok, %A2A.Task{id: task_id, status: A2A.Task.Status.new(:canceled)}}
  end

  @impl true
  def handle_set_push_config(config, _params, %{store: store}) do
    config =
      if config.id, do: config, else: %{config | id: A2A.ID.generate("pcfg")}

    :ets.insert(store, {{config.task_id, config.id}, config})
    {:ok, config}
  end

  @impl true
  def handle_get_push_config(task_id, config_id, _params, %{store: store}) do
    case :ets.lookup(store, {task_id, config_id}) do
      [{_, config}] -> {:ok, config}
      [] -> {:error, Error.task_not_found("Push config not found")}
    end
  end

  @impl true
  def handle_list_push_configs(task_id, _params, %{store: store}) do
    configs =
      :ets.match_object(store, {{task_id, :_}, :_})
      |> Enum.map(fn {_, config} -> config end)

    {:ok, configs}
  end

  @impl true
  def handle_delete_push_config(task_id, config_id, _params, %{store: store}) do
    case :ets.lookup(store, {task_id, config_id}) do
      [{_, _}] ->
        :ets.delete(store, {task_id, config_id})
        :ok

      [] ->
        {:error, Error.task_not_found("Push config not found")}
    end
  end
end
