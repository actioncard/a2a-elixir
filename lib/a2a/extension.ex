defmodule A2A.Extension do
  @moduledoc """
  Behaviour for A2A v1.0 protocol extensions.

  An extension module advertises a URI in its `c:declaration/1`, optionally
  participates in per-request activation via `c:activate/3`, and can hook into
  the request/response pipeline via `c:handle_request/3` and
  `c:handle_response/3`. Configured on `A2A.Plug` and `A2A.Client` as a list
  of `module()` or `{module(), keyword()}` tuples.

  See the [A2A v1.0 extensions topic](https://a2a-protocol.org/dev/topics/extensions/)
  for protocol-level semantics. This module implements the data-only and
  profile extension categories; method extensions (registering new RPC
  methods) and state-machine extensions are not yet supported.

  ## Defining an extension

      defmodule MyApp.TimestampExtension do
        @behaviour A2A.Extension
        @uri "https://example.com/ext/timestamp"

        @impl true
        def declaration(_state) do
          %A2A.AgentExtension{uri: @uri, description: "Adds request timestamps"}
        end

        @impl true
        def activate(_requested_uris, _ctx, _state) do
          {:ok, System.system_time(:millisecond)}
        end

        @impl true
        def handle_response(task, _params, started_at) do
          {:ok, A2A.Extension.put_metadata(task, __MODULE__, %{started_at: started_at}),
           started_at}
        end
      end

  ## Activation model

  At Plug/Client init time each configured extension's `c:init/1` is called
  with its opts; the returned state is kept alongside the module. Per
  request, the server parses the `A2A-Extensions` header and for each
  configured extension whose declared URI is in the requested set, calls
  `c:activate/3` with the requested URI list, the request context, and the
  init state. `c:activate/3` may return `{:ok, activation}` to participate,
  `:skip` to opt out for this request, or `{:error, error}` to abort with
  a JSON-RPC error. The list of activated URIs is echoed in the response
  `A2A-Extensions` header.

  Required extensions (`required: true` in `c:declaration/1`) that are not
  declared in the client's request header trigger
  `ExtensionSupportRequiredError` (-32008) before activation runs.

  ## Hooks

  Activated extensions can mutate the request or response:

  - `c:handle_request/3` — receives the decoded message, JSON-RPC params,
    and the extension's activation. Runs in declaration order before the
    request is dispatched to the agent.
  - `c:handle_response/3` — receives the task, JSON-RPC params, and the
    activation. Runs in declaration order after the agent replies and
    before the task is encoded.

  Both callbacks are optional; data-only extensions implement neither.

  ## Reading activations inside an agent

  Activations are surfaced to the agent's `handle_message/2` as
  `context.extensions`, a `%{uri => activation}` map. The
  `A2A.Extension.fetch/2` and `A2A.Extension.activated?/2` helpers look up
  by module rather than URI string.

      def handle_message(message, context) do
        case A2A.Extension.fetch(context, MyApp.TimestampExtension) do
          {:ok, started_at} -> use_timestamp(message, started_at)
          :error -> handle_without(message)
        end
      end

  ## Configuring extensions

  Server side, pass `:extensions` to `A2A.Plug`. The configured
  declarations are merged into `capabilities.extensions` on the served
  agent card, and the negotiation pipeline runs around every JSON-RPC
  dispatch.

      # Standalone with Bandit
      Bandit.start_link(
        plug: {A2A.Plug,
          agent: MyAgent,
          base_url: "http://localhost:4000",
          extensions: [A2A.Extension.Timestamp, {MyApp.Passport, issuer: "acme"}]}
      )

      # Or in a Phoenix router
      forward "/a2a", A2A.Plug,
        agent: MyAgent,
        base_url: "http://localhost:4000/a2a",
        extensions: [A2A.Extension.Timestamp]

  Client side, pass `:extensions` to `A2A.Client.new/2`. The configured
  URIs are sent in the `A2A-Extensions` request header on every call.
  `A2A.Client.parse_extensions_header/1` and
  `A2A.Client.activated/2` read the server's response header to discover
  which extensions actually ran.

      client = A2A.Client.new("http://localhost:4000",
        extensions: [A2A.Extension.Timestamp])

      {:ok, task} = A2A.Client.send_message(client, "hi")
      task.metadata[A2A.Extension.Timestamp.uri()]
      #=> %{"received_at" => ..., "completed_at" => ...}

  ## Reference

  `A2A.Extension.Timestamp` ships in-tree as a complete profile-extension
  example covering `c:declaration/1`, `c:activate/3`,
  `c:handle_request/3`, and `c:handle_response/3`. See
  [`examples/extensions.exs`](https://github.com/actioncard/a2a-elixir/blob/main/examples/extensions.exs)
  for an end-to-end runnable demo.
  """

  alias A2A.{Artifact, JSONRPC, Message, Task}

  @typedoc "An extension's per-request activation value (opaque to the framework)."
  @type activation :: term()

  @typedoc "An extension's init state (returned from `c:init/1`)."
  @type state :: term()

  @typedoc "User-facing extension configuration entry."
  @type config_entry :: module() | {module(), keyword()}

  @typedoc """
  Internal compiled extension entry. Pipeline state: the module, its init
  state, and its (cached) declaration.
  """
  @type compiled :: {module(), state(), A2A.AgentExtension.t()}

  @typedoc "Ordered list of activations for hook chaining."
  @type activations :: [{module(), activation(), String.t()}]

  @doc """
  Validates and compiles the extension's options. Called once when the
  parent plug or client is initialised. The returned value is threaded
  back into the remaining callbacks as the `state` argument.

  Defaults to ignoring opts and returning `nil`.
  """
  @callback init(opts :: keyword()) :: state()

  @doc """
  Returns the `%A2A.AgentExtension{}` describing this extension. The URI is
  used both for agent-card advertisement and for matching against the
  `A2A-Extensions` request header.
  """
  @callback declaration(state()) :: A2A.AgentExtension.t()

  @doc """
  Called once per request when the client has declared this extension in
  its `A2A-Extensions` header. Returns the activation value that is
  threaded through subsequent hooks, or `:skip` to opt out for this
  request, or `{:error, error}` to abort the request.

  Defaults to `{:ok, nil}` (always activate, no per-request state).
  """
  @callback activate(requested_uris :: [String.t()], ctx :: map(), state()) ::
              {:ok, activation()} | :skip | {:error, JSONRPC.Error.t()}

  @doc """
  Optional. Mutate the inbound message or JSON-RPC params before dispatch.
  Runs in declaration order across activated extensions.
  """
  @callback handle_request(Message.t(), params :: map(), activation()) ::
              {:ok, Message.t(), params :: map(), activation()}
              | {:error, JSONRPC.Error.t()}

  @doc """
  Optional. Mutate the outbound task before encoding. Runs in declaration
  order across activated extensions.
  """
  @callback handle_response(Task.t(), params :: map(), activation()) ::
              {:ok, Task.t(), activation()}

  @optional_callbacks init: 1, activate: 3, handle_request: 3, handle_response: 3

  # ---------------------------------------------------------------------------
  # Public helpers (used by extension authors and agent code)
  # ---------------------------------------------------------------------------

  @doc """
  Fetches the activation value for the given extension module from a
  request context. Returns `{:ok, activation}` or `:error`.
  """
  @spec fetch(map(), module()) :: {:ok, activation()} | :error
  def fetch(%{extensions: extensions}, module) when is_atom(module) do
    Map.fetch(extensions, uri_of(module))
  end

  def fetch(_ctx, _module), do: :error

  @doc """
  Returns `true` if the given extension module is activated in the context.
  """
  @spec activated?(map(), module()) :: boolean()
  def activated?(ctx, module), do: match?({:ok, _}, fetch(ctx, module))

  @doc """
  Convenience for namespacing a value under an extension's URI inside the
  `metadata` field of a `Message`, `Artifact`, or `Task`.
  """
  @spec put_metadata(Message.t() | Artifact.t() | Task.t(), module(), term()) ::
          Message.t() | Artifact.t() | Task.t()
  def put_metadata(%Message{} = msg, module, value) do
    %{msg | metadata: Map.put(msg.metadata || %{}, uri_of(module), value)}
  end

  def put_metadata(%Artifact{} = artifact, module, value) do
    %{artifact | metadata: Map.put(artifact.metadata || %{}, uri_of(module), value)}
  end

  def put_metadata(%Task{} = task, module, value) do
    %{task | metadata: Map.put(task.metadata || %{}, uri_of(module), value)}
  end

  defp uri_of(module) do
    Code.ensure_loaded!(module)
    state = if function_exported?(module, :init, 1), do: module.init([]), else: nil
    module.declaration(state).uri
  end

  # ---------------------------------------------------------------------------
  # Pipeline (used internally by A2A.Plug, A2A.JSONRPC, A2A.Client)
  # ---------------------------------------------------------------------------

  @doc false
  @spec compile([config_entry()]) :: [compiled()]
  def compile(entries) when is_list(entries) do
    Enum.map(entries, &compile_entry/1)
  end

  defp compile_entry(module) when is_atom(module), do: compile_entry({module, []})

  defp compile_entry({module, opts}) when is_atom(module) and is_list(opts) do
    Code.ensure_loaded!(module)
    state = if function_exported?(module, :init, 1), do: module.init(opts), else: nil
    {module, state, module.declaration(state)}
  end

  @doc """
  Parses a list of raw `A2A-Extensions` header values (HTTP allows multiple
  values, each potentially comma-separated) into a deduplicated list of
  requested URIs.
  """
  @spec parse_header([String.t()] | String.t() | nil) :: [String.t()]
  def parse_header(nil), do: []
  def parse_header(value) when is_binary(value), do: parse_header([value])

  def parse_header(values) when is_list(values) do
    values
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Returns the URIs of declarations that are marked `required: true`.
  """
  @spec required_uris([compiled()]) :: [String.t()]
  def required_uris(compiled) do
    for {_mod, _state, %A2A.AgentExtension{required: true, uri: uri}} <- compiled, do: uri
  end

  @doc """
  Returns the URIs declared by all compiled extensions, in declaration order.
  """
  @spec declared_uris([compiled()]) :: [String.t()]
  def declared_uris(compiled) do
    for {_mod, _state, %A2A.AgentExtension{uri: uri}} <- compiled, do: uri
  end

  @doc """
  Returns the declarations of all compiled extensions, in declaration order.
  """
  @spec declarations([compiled()]) :: [A2A.AgentExtension.t()]
  def declarations(compiled) do
    for {_mod, _state, decl} <- compiled, do: decl
  end

  @doc """
  Validates required-extension presence against the client's requested URIs.
  Returns `:ok` or `{:error, missing_uris}`.
  """
  @spec validate_required([compiled()], [String.t()]) ::
          :ok | {:error, [String.t()]}
  def validate_required(compiled, requested) when is_list(requested) do
    case Enum.reject(required_uris(compiled), &(&1 in requested)) do
      [] -> :ok
      missing -> {:error, missing}
    end
  end

  @doc """
  Runs `activate/3` for each configured extension whose declared URI is in
  the requested list. Returns an ordered list of `{module, activation, uri}`
  tuples and the matching URI list, or an error if any extension's
  `activate/3` returned `{:error, ...}`.
  """
  @spec activate([compiled()], [String.t()], map()) ::
          {:ok, activations(), [String.t()]} | {:error, JSONRPC.Error.t()}
  def activate(compiled, requested, ctx) when is_list(requested) do
    Enum.reduce_while(compiled, {:ok, [], []}, fn {mod, state, decl}, {:ok, acts, uris} ->
      if decl.uri in requested do
        case do_activate(mod, requested, ctx, state) do
          {:ok, activation} ->
            {:cont, {:ok, [{mod, activation, decl.uri} | acts], [decl.uri | uris]}}

          :skip ->
            {:cont, {:ok, acts, uris}}

          {:error, %JSONRPC.Error{} = err} ->
            {:halt, {:error, err}}
        end
      else
        {:cont, {:ok, acts, uris}}
      end
    end)
    |> case do
      {:ok, acts, uris} -> {:ok, Enum.reverse(acts), Enum.reverse(uris)}
      {:error, _} = error -> error
    end
  end

  defp do_activate(module, requested, ctx, state) do
    if function_exported?(module, :activate, 3) do
      module.activate(requested, ctx, state)
    else
      {:ok, nil}
    end
  end

  @doc """
  Runs the `handle_request/3` chain over an activated extension list.
  Returns possibly-mutated message, params, and the (possibly-updated)
  activations list, or `{:error, error}` if any extension aborted.
  """
  @spec run_request(activations(), Message.t(), map()) ::
          {:ok, Message.t(), map(), activations()} | {:error, JSONRPC.Error.t()}
  def run_request(activations, message, params) do
    Enum.reduce_while(activations, {:ok, message, params, []}, fn {mod, act, uri},
                                                                  {:ok, msg, p, acc} ->
      if function_exported?(mod, :handle_request, 3) do
        case mod.handle_request(msg, p, act) do
          {:ok, msg2, p2, act2} -> {:cont, {:ok, msg2, p2, [{mod, act2, uri} | acc]}}
          {:error, %JSONRPC.Error{} = err} -> {:halt, {:error, err}}
        end
      else
        {:cont, {:ok, msg, p, [{mod, act, uri} | acc]}}
      end
    end)
    |> case do
      {:ok, msg, p, acc} -> {:ok, msg, p, Enum.reverse(acc)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Runs the `handle_response/3` chain over an activated extension list.
  Returns the possibly-mutated task and the updated activations list.
  """
  @spec run_response(activations(), Task.t(), map()) ::
          {:ok, Task.t(), activations()}
  def run_response(activations, task, params) do
    {task, acc} =
      Enum.reduce(activations, {task, []}, fn {mod, act, uri}, {t, acc} ->
        if function_exported?(mod, :handle_response, 3) do
          {:ok, t2, act2} = mod.handle_response(t, params, act)
          {t2, [{mod, act2, uri} | acc]}
        else
          {t, [{mod, act, uri} | acc]}
        end
      end)

    {:ok, task, Enum.reverse(acc)}
  end

  @doc """
  Converts the ordered activations list into the `%{uri => activation}`
  map exposed to the agent via `context.extensions`.
  """
  @spec to_context_map(activations()) :: %{String.t() => activation()}
  def to_context_map(activations) do
    Map.new(activations, fn {_mod, act, uri} -> {uri, act} end)
  end
end
