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
  Returns the encoded agent card for a local agent.

  Fetches the card via GenServer and encodes it using
  `A2A.JSON.encode_agent_card/2`. This is useful for serving agent
  cards from custom endpoints (e.g., a Phoenix controller) when you
  set `agent_card_path: false` on `A2A.Plug`.

  ## Options

  - `:base_url` — the public URL of the agent endpoint (required)
  - All other options are forwarded to `A2A.JSON.encode_agent_card/2`

  ## Examples

      A2A.get_agent_card(MyAgent, base_url: "https://example.com/a2a")
      # => %{"name" => ..., "url" => "https://example.com/a2a", ...}
  """
  @spec get_agent_card(GenServer.server(), keyword()) :: map()
  def get_agent_card(agent, opts) do
    {base_url, encode_opts} = Keyword.pop!(opts, :base_url)
    card = GenServer.call(agent, :get_agent_card)
    A2A.JSON.encode_agent_card(card, [{:url, base_url} | encode_opts])
  end

  @doc """
  Sends a message to a local agent and returns the resulting task.

  The `agent` can be a module name (registered GenServer) or a PID.
  The `message` can be a string, an `A2A.Message.t()`, or a list of parts.

  ## Options

  - `:context_id` — associate the message with a conversation context
  - `:task_id` — continue an existing task (must be in a non-terminal state)
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
    meta = %{agent: agent, streaming: false}

    :telemetry.span([:a2a, :agent, :call], meta, fn ->
      case GenServer.call(agent, {:message, message, opts}, timeout) do
        {:ok, task} = result ->
          {result,
           Map.merge(meta, %{
             task_id: task.id,
             status: task.status.state,
             context_id: task.context_id
           })}

        {:error, reason} = result ->
          {result, Map.put(meta, :error, reason)}
      end
    end)
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
    meta = %{agent: agent, streaming: true}

    :telemetry.span([:a2a, :agent, :call], meta, fn ->
      case GenServer.call(agent, {:message, message, opts}, timeout) do
        {:ok, %A2A.Task{metadata: %{stream: enum}} = task} ->
          result = {:ok, task, enum}

          {result,
           Map.merge(meta, %{
             task_id: task.id,
             status: task.status.state,
             context_id: task.context_id
           })}

        {:ok, task} ->
          result = {:error, {:not_streaming, task}}
          {result, Map.put(meta, :error, {:not_streaming, task})}

        {:error, reason} = result ->
          {result, Map.put(meta, :error, reason)}
      end
    end)
  end
end
