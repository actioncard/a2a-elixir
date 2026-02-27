defmodule A2A.Test.Handler do
  @moduledoc false
  @behaviour A2A.JSONRPC

  alias A2A.JSONRPC.Error

  @impl true
  def handle_send(message, _params) do
    task = %A2A.Task{
      id: A2A.ID.generate("tsk"),
      status: A2A.Task.Status.new(:completed),
      history: [message]
    }

    {:ok, task}
  end

  @impl true
  def handle_get("existing", _params) do
    {:ok,
     %A2A.Task{
       id: "existing",
       status: A2A.Task.Status.new(:working)
     }}
  end

  def handle_get(_task_id, _params) do
    {:error, Error.task_not_found()}
  end

  @impl true
  def handle_cancel("cancelable", _params) do
    {:ok,
     %A2A.Task{
       id: "cancelable",
       status: A2A.Task.Status.new(:canceled)
     }}
  end

  def handle_cancel(_task_id, _params) do
    {:error, Error.task_not_cancelable()}
  end
end
