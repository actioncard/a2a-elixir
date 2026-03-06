defmodule A2A.Agent do
  @moduledoc """
  Behaviour for defining A2A agents.

  Agents are the primary abstraction in the A2A library. Each agent declares
  its identity and capabilities via `agent_card/0` and implements message
  handling via `handle_message/2`.

  ## Usage

      defmodule MyApp.GreeterAgent do
        use A2A.Agent,
          name: "greeter",
          description: "Greets users",
          skills: [
            %{id: "greet", name: "Greet", description: "Says hello", tags: []}
          ]

        @impl A2A.Agent
        def handle_message(message, _context) do
          text = A2A.Message.text(message)
          {:reply, [A2A.Part.Text.new("Hello, \#{text}!")]}
        end
      end

  The `use` macro accepts shorthand options for `agent_card/0`:

  - `:name` — agent name (required unless `agent_card/0` is defined manually)
  - `:description` — agent description (default: `""`)
  - `:version` — agent version (default: `"0.1.0"`)
  - `:skills` — list of skill maps (default: `[]`)
  - `:opts` — additional keyword options (default: `[]`)

  ## Architecture

  `use A2A.Agent` generates a full GenServer. The agent author only implements
  the behaviour callbacks — the runtime manages task lifecycle, state
  transitions, history accumulation, and persistence.

  Internally, three modules collaborate:

  - **`A2A.Agent`** (this module) — the behaviour definition and the `use`
    macro that generates GenServer client API and callbacks.
  - **Agent.Runtime** (internal) — pure functions for message processing.
    Creates tasks, calls `handle_message/2`, maps reply tuples to state
    transitions. Also handles task continuation (multi-turn) and stream
    wrapping.
  - **Agent.State** (internal) — the internal GenServer state struct. Holds
    the task map, context index, and optional task store reference. Provides
    helpers for task storage, retrieval, and state transitions.

  ## Task Lifecycle

  The runtime manages a task state machine so agent implementations don't
  have to. Each message creates (or continues) a task that progresses through:

      :submitted → :working → :completed
                            → :failed
                            → :input_required → (new message) → :working → ...
                            → :canceled

  The reply from `handle_message/2` determines the transition:

  - `{:reply, parts}` — creates an artifact, transitions to `:completed`
  - `{:input_required, parts}` — transitions to `:input_required`, caller
    can continue the same task by passing `task_id:` to the next call
  - `{:stream, enumerable}` — stays `:working`, transitions to `:completed`
    when the caller fully consumes the stream
  - `{:error, reason}` — transitions to `:failed`

  ## Reply Parts and Status

  The parts returned from `handle_message/2` serve double duty: they are
  appended to the task's `history` (as an agent message) **and**, for
  `{:input_required, parts}`, set as the task's `status.message`.

  These two fields have different audiences:

  - **`history`** — the full conversation transcript, used by agent logic
    for context on subsequent turns.
  - **`status.message`** — a short prompt surfaced to the client UI,
    explaining why the task is paused and what input is needed.

  Because both are populated from the same parts, keep
  `{:input_required, parts}` **concise and actionable**:

      # Good — short prompt that works as both history entry and status
      {:input_required, [Part.Text.new("What size pizza?")]}

      # Avoid — long explanation duplicated into status.message
      {:input_required, [Part.Text.new("Here's our full menu... What size?")]}

  For `{:reply, parts}` and `{:stream, enumerable}`, the parts only go
  into `history` and `artifacts` — `status.message` is left empty.

  ## Multi-Turn Conversations

  When an agent returns `{:input_required, parts}`, the task pauses. The
  caller continues it by passing `task_id:` with the next message:

      {:ok, task} = A2A.call(agent, "order pizza")
      # task.status.state == :input_required
      {:ok, task} = A2A.call(agent, "large", task_id: task.id)
      # task.status.state may be :completed or :input_required again

  The runtime appends each message to the task's history, so the agent
  receives the full conversation in `context.history`.

  ## Streaming

  When an agent returns `{:stream, enumerable}`, the runtime wraps the
  stream so that consuming it automatically finalizes the task:

      {:ok, task, stream} = A2A.stream(agent, "count to 5")
      Enum.each(stream, &IO.inspect/1)
      # task is now :completed with an artifact containing all streamed parts

  ## Persistence

  By default, tasks live in the GenServer's process state (in-memory map).
  For external persistence, pass a task store at startup:

      MyAgent.start_link(task_store: {A2A.TaskStore.ETS, :my_table})

  The runtime writes every task update to both the internal map and the
  external store. See `A2A.TaskStore` for the behaviour interface.

  ## Starting an Agent

      {:ok, pid} = MyAgent.start_link()
      {:ok, task} = A2A.call(MyAgent, "hello")

  Or with options:

      MyAgent.start_link(name: :my_agent, task_store: {A2A.TaskStore.ETS, :tasks})
  """

  @type card :: %{
          name: String.t(),
          description: String.t(),
          version: String.t(),
          skills: [skill()],
          opts: keyword()
        }

  @type skill :: %{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          tags: [String.t()]
        }

  @type context :: %{
          task_id: String.t(),
          context_id: String.t() | nil,
          history: [A2A.Message.t()],
          metadata: map()
        }

  @type reply ::
          {:reply, [A2A.Part.t()]}
          | {:stream, Enumerable.t()}
          | {:input_required, [A2A.Part.t()]}
          | {:error, term()}

  @doc """
  Returns the agent's identity and capabilities.
  """
  @callback agent_card() :: card()

  @doc """
  Handles an incoming message. This is the core agent logic.
  """
  @callback handle_message(A2A.Message.t(), context()) :: reply()

  @doc """
  Called when a task is canceled by the caller. Optional.
  """
  @callback handle_cancel(context()) :: :ok | {:error, String.t()}

  @doc false
  defmacro __using__(opts) do
    card_ast = build_card_ast(opts)

    quote location: :keep do
      use GenServer

      @behaviour A2A.Agent

      unquote(card_ast)

      @impl A2A.Agent
      def handle_cancel(_context), do: :ok

      defoverridable handle_cancel: 1

      # --- GenServer client API ---

      @doc """
      Starts the agent process.

      ## Options

      - `:name` — process registration name (default: module name)
      - `:task_store` — `{module, opts}` tuple for external task persistence
      """
      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts \\ []) do
        {name, opts} = Keyword.pop(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, opts, name: name)
      end

      @doc """
      Sends a message to the agent and returns the resulting task.

      ## Options

      - `:timeout` — GenServer call timeout in ms (default: `60_000`)
      """
      @spec call(GenServer.server(), A2A.Message.t(), keyword()) ::
              {:ok, A2A.Task.t()} | {:error, term()}
      def call(server \\ __MODULE__, message, opts \\ []) do
        {timeout, opts} = Keyword.pop(opts, :timeout, 60_000)
        GenServer.call(server, {:message, message, opts}, timeout)
      end

      @doc """
      Cancels a running task.

      ## Options

      - `:timeout` — GenServer call timeout in ms (default: `60_000`)
      """
      @spec cancel(GenServer.server(), String.t(), keyword()) ::
              :ok | {:error, term()}
      def cancel(server \\ __MODULE__, task_id, opts \\ []) do
        {timeout, _opts} = Keyword.pop(opts, :timeout, 60_000)
        GenServer.call(server, {:cancel, task_id}, timeout)
      end

      @doc """
      Retrieves a task by ID.

      ## Options

      - `:timeout` — GenServer call timeout in ms (default: `5_000`)
      """
      @spec get_task(GenServer.server(), String.t(), keyword()) ::
              {:ok, A2A.Task.t()} | {:error, :not_found}
      def get_task(server \\ __MODULE__, task_id, opts \\ []) do
        {timeout, _opts} = Keyword.pop(opts, :timeout, 5_000)
        GenServer.call(server, {:get_task, task_id}, timeout)
      end

      # --- GenServer callbacks ---

      @impl GenServer
      def init(opts) do
        task_store = Keyword.get(opts, :task_store)

        {:ok,
         %A2A.Agent.State{
           module: __MODULE__,
           task_store: task_store
         }}
      end

      @impl GenServer
      def handle_call({:message, message, opts}, from, state) do
        task_id = Keyword.get(opts, :task_id)
        context_id = Keyword.get(opts, :context_id)
        metadata = Keyword.get(opts, :metadata, %{})

        result =
          if task_id do
            case A2A.Agent.State.get_task(state, task_id) do
              {:ok, task} ->
                A2A.Agent.Runtime.continue_task(__MODULE__, message, task, state)

              {:error, :not_found} ->
                {:error, :not_found}
            end
          else
            {:ok,
             A2A.Agent.Runtime.process_message(
               __MODULE__,
               message,
               context_id,
               state,
               metadata
             )}
          end

        case result do
          {:ok, {task, state}} ->
            task = maybe_wrap_stream(task, from)
            state = A2A.Agent.State.put_task(state, task)
            {:reply, {:ok, task}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      end

      def handle_call({:cancel, task_id}, _from, state) do
        case A2A.Agent.State.get_task(state, task_id) do
          {:ok, task} ->
            context = %{
              task_id: task.id,
              context_id: task.context_id,
              history: task.history,
              metadata: task.metadata
            }

            span_meta = %{
              agent: __MODULE__,
              task_id: task.id,
              context_id: task.context_id
            }

            result =
              :telemetry.span([:a2a, :agent, :cancel], span_meta, fn ->
                {A2A.Agent.Runtime.run_cancel(__MODULE__, context), span_meta}
              end)

            case result do
              :ok ->
                task = A2A.Agent.State.transition(task, :canceled)
                state = A2A.Agent.State.put_task(state, task)
                {:reply, :ok, state}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          {:error, :not_found} ->
            {:reply, {:error, :not_found}, state}
        end
      end

      def handle_call({:get_task, task_id}, _from, state) do
        {:reply, A2A.Agent.State.get_task(state, task_id), state}
      end

      def handle_call({:list_tasks, params}, _from, state) do
        {:reply, A2A.Agent.State.list_tasks(state, params), state}
      end

      def handle_call(:get_agent_card, _from, state) do
        {:reply, __MODULE__.agent_card(), state}
      end

      @impl GenServer
      def handle_cast({:stream_done, task_id, parts}, state) do
        case A2A.Agent.State.get_task(state, task_id) do
          {:ok, task} ->
            artifact = A2A.Artifact.new(parts)
            agent_msg = A2A.Message.new_agent(parts)
            task = %{task | artifacts: task.artifacts ++ [artifact]}
            task = %{task | history: task.history ++ [agent_msg]}
            task = %{task | metadata: Map.delete(task.metadata, :stream)}
            task = A2A.Agent.State.transition(task, :completed)
            state = A2A.Agent.State.put_task(state, task)
            {:noreply, state}

          {:error, :not_found} ->
            {:noreply, state}
        end
      end

      defp maybe_wrap_stream(%{metadata: %{stream: enum}} = task, {pid, _ref}) do
        wrapped = A2A.Agent.Runtime.wrap_stream(enum, self(), task.id)
        %{task | metadata: Map.put(task.metadata, :stream, wrapped)}
      end

      defp maybe_wrap_stream(task, _from), do: task
    end
  end

  defp build_card_ast(opts) do
    if Keyword.has_key?(opts, :name) do
      name = Keyword.fetch!(opts, :name)
      description = Keyword.get(opts, :description, "")
      version = Keyword.get(opts, :version, "0.1.0")
      skills = Keyword.get(opts, :skills, [])
      extra_opts = Keyword.get(opts, :opts, [])

      quote do
        @impl A2A.Agent
        def agent_card do
          %{
            name: unquote(name),
            description: unquote(description),
            version: unquote(version),
            skills: unquote(skills),
            opts: unquote(extra_opts)
          }
        end

        defoverridable agent_card: 0
      end
    else
      quote do
      end
    end
  end
end
