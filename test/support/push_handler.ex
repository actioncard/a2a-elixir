defmodule A2A.Test.PushHandler do
  @moduledoc false
  @behaviour A2A.JSONRPC

  alias A2A.JSONRPC.Error
  alias A2A.PushNotificationConfig

  @known_task "tsk-known"
  @known_config "pcfg-known"

  def known_task, do: @known_task

  def known_config_id, do: @known_config

  def known_config do
    %PushNotificationConfig{
      id: @known_config,
      task_id: @known_task,
      url: "https://example.com/hook",
      authentication: %{scheme: "Bearer", credentials: "s3cret"}
    }
  end

  @impl true
  def handle_send(_message, _params, _context), do: {:error, Error.unsupported_operation()}

  @impl true
  def handle_get(_task_id, _params, _context), do: {:error, Error.task_not_found()}

  @impl true
  def handle_cancel(_task_id, _params, _context), do: {:error, Error.task_not_found()}

  # Echoes the decoded config back, so tests can assert on exactly what the
  # dispatch layer parsed out of the request params.
  @impl true
  def handle_set_push_config(%PushNotificationConfig{} = config, _params, _context) do
    {:ok, %{config | id: config.id || "pcfg-generated"}}
  end

  @impl true
  def handle_get_push_config(@known_task, @known_config, _params, _context) do
    {:ok, known_config()}
  end

  def handle_get_push_config(_task_id, _config_id, _params, _context) do
    {:error, Error.task_not_found("Push notification config not found")}
  end

  @impl true
  def handle_list_push_configs(@known_task, _params, _context), do: {:ok, [known_config()]}
  def handle_list_push_configs(_task_id, _params, _context), do: {:ok, []}

  @impl true
  def handle_delete_push_config(_task_id, _config_id, _params, _context), do: :ok
end
