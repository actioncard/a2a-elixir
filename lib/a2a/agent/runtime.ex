defmodule A2A.Agent.Runtime do
  @moduledoc false

  alias A2A.Agent.State
  alias A2A.{Artifact, Message, Task}

  @doc """
  Calls the agent's `handle_cancel/1` callback via `apply/3`.
  """
  @spec run_cancel(module(), A2A.Agent.context()) :: :ok | {:error, String.t()}
  def run_cancel(module, context) do
    apply(module, :handle_cancel, [context])
  end

  @doc """
  Processes an incoming message through the agent's task lifecycle.

  Creates a new task, transitions through states, and calls `handle_message/2`.
  """
  @spec process_message(module(), Message.t(), String.t() | nil, State.t(), map()) ::
          {Task.t(), State.t()}
  def process_message(module, message, context_id, state, metadata \\ %{}) do
    task = Task.new(context_id: context_id, metadata: metadata)
    task = %{task | history: [message]}
    run_task(module, message, task, state)
  end

  @doc """
  Continues an existing task with a new message.

  Appends the message to the task's history and re-runs `handle_message/2`.
  Valid for any non-terminal task state.
  """
  @spec continue_task(module(), Message.t(), Task.t(), State.t()) ::
          {:ok, {Task.t(), State.t()}} | {:error, :not_continuable}
  def continue_task(module, message, task, state) do
    if Task.terminal?(task) do
      {:error, :not_continuable}
    else
      task = %{task | history: task.history ++ [message]}
      task = %{task | metadata: Map.delete(task.metadata, :stream)}
      {:ok, run_task(module, message, task, state)}
    end
  end

  @doc """
  Wraps a stream so that consuming it notifies the agent GenServer to
  finalize the task (transition to `:completed`, create artifact).
  """
  @spec wrap_stream(Enumerable.t(), GenServer.server(), String.t()) :: Enumerable.t()
  def wrap_stream(enum, server, task_id) do
    Stream.transform(
      enum,
      fn -> [] end,
      fn part, acc -> {[part], [part | acc]} end,
      fn acc ->
        parts = Enum.reverse(acc)
        GenServer.cast(server, {:stream_done, task_id, parts})
      end
    )
  end

  defp run_task(module, message, task, state) do
    task = State.transition(task, :working)

    context = %{
      task_id: task.id,
      context_id: task.context_id,
      history: task.history,
      metadata: task.metadata
    }

    meta = %{agent: module, task_id: task.id, context_id: task.context_id}

    reply =
      :telemetry.span([:a2a, :agent, :message], meta, fn ->
        result = module.handle_message(message, context)
        reply_type = elem(result, 0)
        {result, Map.put(meta, :reply_type, reply_type)}
      end)

    task = handle_reply(reply, task)
    state = State.track_context(state, task)
    {task, state}
  end

  defp handle_reply({:reply, parts}, task) do
    artifact = Artifact.new(parts)
    agent_msg = Message.new_agent(parts)
    task = %{task | artifacts: task.artifacts ++ [artifact]}
    task = %{task | history: task.history ++ [agent_msg]}
    State.transition(task, :completed)
  end

  defp handle_reply({:input_required, parts}, task) do
    agent_msg = Message.new_agent(parts)
    task = %{task | history: task.history ++ [agent_msg]}
    State.transition(task, :input_required, agent_msg)
  end

  defp handle_reply({:error, reason}, task) do
    error_msg = Message.new_agent("Error: #{inspect(reason)}")
    State.transition(task, :failed, error_msg)
  end

  defp handle_reply({:stream, enum}, task) do
    %{task | metadata: Map.put(task.metadata, :stream, enum)}
  end
end
