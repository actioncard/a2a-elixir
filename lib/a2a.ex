defmodule A2A do
  @moduledoc """
  Elixir implementation of the Agent-to-Agent (A2A) protocol.

  A2A provides a behaviour-based agent framework where agents are local
  GenServer processes. Use `A2A.call/3` and `A2A.stream/3` to interact
  with agents.

  ## Quick Start

      # Define an agent
      defmodule MyAgent do
        use A2A.Agent,
          name: "my-agent",
          description: "Does things"

        @impl A2A.Agent
        def handle_message(message, _context) do
          {:reply, [A2A.Part.Text.new("Got: \#{A2A.Message.text(message)}")]}
        end
      end

      # Start and call it
      {:ok, _pid} = MyAgent.start_link()
      {:ok, task} = A2A.call(MyAgent, "hello")
  """

  @doc """
  Sends a message to a local agent and returns the resulting task.

  The `agent` can be a module name (registered GenServer) or a PID.
  The `message` can be a string, an `A2A.Message.t()`, or a list of parts.

  ## Options

  - `:context_id` — associate the message with a conversation context
  - `:task_id` — continue an existing task (must be in `:input_required` state)
  - `:timeout` — GenServer call timeout in ms (default: `60_000`)

  ## Examples

      A2A.call(MyAgent, "hello")
      A2A.call(MyAgent, message, context_id: "ctx-123")

      # Multi-turn: continue an input_required task
      {:ok, task} = A2A.call(MyAgent, "order pizza")
      {:ok, task} = A2A.call(MyAgent, "large", task_id: task.id)
  """
  @spec call(GenServer.server(), String.t() | A2A.Message.t(), keyword()) ::
          {:ok, A2A.Task.t()} | {:error, term()}
  def call(agent, message, opts \\ [])

  def call(agent, message, opts) when is_binary(message) do
    call(agent, A2A.Message.new_user(message), opts)
  end

  def call(agent, %A2A.Message{} = message, opts) do
    {timeout, opts} = Keyword.pop(opts, :timeout, 60_000)
    GenServer.call(agent, {:message, message, opts}, timeout)
  end

  @doc """
  Sends a message to a streaming agent and returns the stream.

  The agent's `handle_message/2` must return `{:stream, enumerable}`.
  The returned stream is lazy — the caller must consume it.

  ## Options

  - `:context_id` — associate the message with a conversation context
  - `:timeout` — GenServer call timeout in ms (default: `60_000`)

  ## Examples

      A2A.stream(MyAgent, "research topic")
      |> Stream.each(&process/1)
      |> Stream.run()
  """
  @spec stream(GenServer.server(), String.t() | A2A.Message.t(), keyword()) ::
          {:ok, A2A.Task.t(), Enumerable.t()} | {:error, term()}
  def stream(agent, message, opts \\ [])

  def stream(agent, message, opts) when is_binary(message) do
    stream(agent, A2A.Message.new_user(message), opts)
  end

  def stream(agent, %A2A.Message{} = message, opts) do
    {timeout, opts} = Keyword.pop(opts, :timeout, 60_000)

    case GenServer.call(agent, {:message, message, opts}, timeout) do
      {:ok, %A2A.Task{metadata: %{stream: enum}} = task} ->
        {:ok, task, enum}

      {:ok, task} ->
        {:error, {:not_streaming, task}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
