if Code.ensure_loaded?(Plug) do
  defmodule A2A.Plug do
    @moduledoc """
    Plug for serving A2A agents over HTTP.

    Handles agent card discovery (GET), JSON-RPC dispatch (POST), and SSE
    streaming. Works standalone with Bandit or mounted inside Phoenix via
    `forward`.

    ## Usage

        # In a Phoenix router:
        forward "/a2a", A2A.Plug, agent: MyAgent, base_url: "http://localhost:4000/a2a"

        # Standalone with Bandit:
        Bandit.start_link(plug: {A2A.Plug, agent: MyAgent, base_url: "http://localhost:4000"})

    ## Options

    - `:agent` — GenServer name or pid of the agent (required)
    - `:base_url` — the public URL of the agent endpoint. Required unless
      always provided at runtime via `put_base_url/2`. When `nil`, agent
      card requests raise `ArgumentError`.
    - `:agent_card_path` — path segments for the agent card endpoint
      (default: `[".well-known", "agent-card.json"]`). Set to `false` to
      disable built-in agent card serving — useful when you want to serve
      the card from a custom route using `A2A.get_agent_card/2`.
    - `:json_rpc_path` — path segments for the JSON-RPC endpoint
      (default: `[]`)
    - `:agent_card_opts` — keyword options forwarded to
      `A2A.JSON.encode_agent_card/2`
    - `:metadata` — static metadata merged into every JSON-RPC call
      (default: `%{}`). Useful for deployment-level metadata like
      `%{"env" => "prod"}`. Overridden per-request by `put_metadata/2`.

    ## Per-Request Overrides

    Use `put_base_url/2` and `put_metadata/2` in an upstream plug or
    Phoenix pipeline to set per-request values. These are stored in
    `conn.private[:a2a]` following the Ash/Absinthe convention.

        plug :set_tenant_a2a

        defp set_tenant_a2a(conn, _opts) do
          conn
          |> A2A.Plug.put_base_url("https://\#{conn.host}/a2a")
          |> A2A.Plug.put_metadata(%{"tenant_id" => conn.assigns.tenant_id})
        end

    ## Metadata Merge Order

    Metadata is merged in three layers (later wins):

    1. `:metadata` from `init/1` (static defaults)
    2. `put_metadata/2` on conn (per-request)
    3. `"metadata"` from JSON-RPC params (per-call from client)
    """

    @behaviour Plug
    @behaviour A2A.JSONRPC

    import Plug.Conn

    alias A2A.JSONRPC.{Error, Response}

    # -- Public helpers for per-request overrides ------------------------------

    @doc """
    Stores a per-request base URL in `conn.private[:a2a]`.

    Use this in an upstream plug or Phoenix pipeline to override the
    `base_url` configured at init time.
    """
    @spec put_base_url(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
    def put_base_url(conn, url) when is_binary(url) do
      a2a = Map.get(conn.private, :a2a, %{})
      put_private(conn, :a2a, Map.put(a2a, :base_url, url))
    end

    @doc """
    Returns the per-request base URL, or `nil` if not set.
    """
    @spec get_base_url(Plug.Conn.t()) :: String.t() | nil
    def get_base_url(conn) do
      conn.private |> Map.get(:a2a, %{}) |> Map.get(:base_url)
    end

    @doc """
    Stores per-request metadata in `conn.private[:a2a]`.

    This metadata is merged between the init-time `:metadata` and the
    per-call JSON-RPC `"metadata"` field.
    """
    @spec put_metadata(Plug.Conn.t(), map()) :: Plug.Conn.t()
    def put_metadata(conn, metadata) when is_map(metadata) do
      a2a = Map.get(conn.private, :a2a, %{})
      put_private(conn, :a2a, Map.put(a2a, :metadata, metadata))
    end

    @doc """
    Returns the per-request metadata, or `nil` if not set.
    """
    @spec get_metadata(Plug.Conn.t()) :: map() | nil
    def get_metadata(conn) do
      conn.private |> Map.get(:a2a, %{}) |> Map.get(:metadata)
    end

    # -- Plug callbacks --------------------------------------------------------

    @impl Plug
    @spec init(keyword()) :: map()
    def init(opts) do
      %{
        agent: Keyword.fetch!(opts, :agent),
        base_url: Keyword.get(opts, :base_url),
        agent_card_path: Keyword.get(opts, :agent_card_path, [".well-known", "agent-card.json"]),
        json_rpc_path: Keyword.get(opts, :json_rpc_path, []),
        agent_card_opts: Keyword.get(opts, :agent_card_opts, []),
        metadata: Keyword.get(opts, :metadata, %{})
      }
    end

    @impl Plug
    @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
    def call(%{method: "GET", path_info: path} = conn, %{agent_card_path: path} = opts) do
      resolved = resolve_opts(conn, opts)
      serve_agent_card(conn, resolved)
    end

    def call(%{method: "POST", path_info: path} = conn, %{json_rpc_path: path} = opts) do
      resolved = resolve_opts(conn, opts)
      handle_json_rpc(conn, resolved)
    end

    def call(%{path_info: path} = conn, %{agent_card_path: path}) do
      conn
      |> put_resp_header("allow", "GET")
      |> send_resp(405, "Method Not Allowed")
    end

    def call(conn, _opts) do
      send_resp(conn, 404, "Not Found")
    end

    # -- Option resolution -----------------------------------------------------

    defp resolve_opts(conn, opts) do
      overrides = Map.get(conn.private, :a2a, %{})

      base_url = Map.get(overrides, :base_url, opts.base_url)
      conn_metadata = Map.get(overrides, :metadata)

      metadata =
        if conn_metadata,
          do: Map.merge(opts.metadata, conn_metadata),
          else: opts.metadata

      auth = Map.get(overrides, :auth)
      metadata = if auth, do: Map.put(metadata, "a2a.auth", auth), else: metadata

      %{opts | base_url: base_url, metadata: metadata}
    end

    # -- Agent card ------------------------------------------------------------

    defp serve_agent_card(_conn, %{base_url: nil}) do
      raise ArgumentError,
            "A2A.Plug requires a base_url for agent card requests. " <>
              "Set it via init option :base_url or A2A.Plug.put_base_url/2."
    end

    defp serve_agent_card(conn, opts) do
      card = GenServer.call(opts.agent, :get_agent_card)

      json =
        A2A.JSON.encode_agent_card(
          card,
          [url: opts.base_url] ++ opts.agent_card_opts
        )

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(json))
    end

    # -- JSON-RPC dispatch -----------------------------------------------------

    defp handle_json_rpc(conn, opts) do
      case read_json_body(conn) do
        {:ok, decoded, conn} ->
          context = %{agent: opts.agent, opts: opts}

          case A2A.JSONRPC.handle(decoded, __MODULE__, context) do
            {:reply, response} ->
              send_json(conn, response)

            {:stream, "message/stream", params, id} ->
              message = params["message"]

              call_opts =
                params
                |> build_call_opts(opts)
                |> maybe_put_fallback(:task_id, message.task_id)
                |> maybe_put_fallback(:context_id, message.context_id)

              A2A.Plug.SSE.stream_message(
                conn,
                opts.agent,
                message,
                id,
                call_opts
              )

            {:stream, "tasks/resubscribe", _params, id} ->
              send_json(conn, Response.error(id, Error.unsupported_operation()))
          end

        {:error, :parse_error} ->
          send_json(conn, Response.error(nil, Error.parse_error()))

        {:error, :body_too_large} ->
          send_json(conn, Response.error(nil, Error.parse_error("Body too large")))

        {:error, reason} ->
          send_json(conn, Response.error(nil, Error.internal_error(inspect(reason))))
      end
    end

    # Returns the decoded JSON body, handling both pre-parsed (Phoenix with
    # Plug.Parsers) and raw (standalone Bandit) request bodies.
    defp read_json_body(%{body_params: %Plug.Conn.Unfetched{}} = conn) do
      case read_body(conn) do
        {:ok, body, conn} ->
          case Jason.decode(body) do
            {:ok, decoded} -> {:ok, decoded, conn}
            {:error, %Jason.DecodeError{}} -> {:error, :parse_error}
          end

        {:more, _partial, _conn} ->
          {:error, :body_too_large}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp read_json_body(%{body_params: %{} = params} = conn) do
      {:ok, params, conn}
    end

    defp send_json(conn, response) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    end

    # -- JSONRPC behaviour callbacks -------------------------------------------

    @impl A2A.JSONRPC
    def handle_send(message, params, %{agent: agent, opts: plug_opts}) do
      call_opts =
        params
        |> build_call_opts(plug_opts)
        |> maybe_put_fallback(:task_id, message.task_id)
        |> maybe_put_fallback(:context_id, message.context_id)

      case A2A.call(agent, message, call_opts) do
        {:ok, task} -> {:ok, task}
        {:error, reason} -> {:error, Error.internal_error(inspect(reason))}
      end
    end

    @impl A2A.JSONRPC
    def handle_get(task_id, _params, %{agent: agent}) do
      case GenServer.call(agent, {:get_task, task_id}) do
        {:ok, task} -> {:ok, task}
        {:error, :not_found} -> {:error, Error.task_not_found()}
      end
    end

    @impl A2A.JSONRPC
    def handle_cancel(task_id, _params, %{agent: agent}) do
      case GenServer.call(agent, {:cancel, task_id}) do
        :ok ->
          case GenServer.call(agent, {:get_task, task_id}) do
            {:ok, task} -> {:ok, task}
            {:error, _} -> {:error, Error.task_not_found()}
          end

        {:error, :not_found} ->
          {:error, Error.task_not_found()}

        {:error, reason} ->
          {:error, Error.task_not_cancelable(inspect(reason))}
      end
    end

    @impl A2A.JSONRPC
    def handle_list(params, %{agent: agent}) do
      case GenServer.call(agent, {:list_tasks, params}) do
        {:ok, result} ->
          {:ok, result}

        {:error, :invalid_page_token} ->
          {:error, Error.invalid_params("\"pageToken\" is invalid")}

        {:error, reason} ->
          {:error, Error.internal_error(inspect(reason))}
      end
    end

    # -- Helpers ---------------------------------------------------------------

    defp build_call_opts(params, plug_opts) do
      # 3-layer metadata merge: init → conn.private → JSON-RPC params
      metadata =
        plug_opts.metadata
        |> merge_unless_nil(params["metadata"])

      []
      |> maybe_put(:task_id, params["id"])
      |> maybe_put(:context_id, params["contextId"])
      |> maybe_put(:metadata, if(metadata == %{}, do: nil, else: metadata))
    end

    defp merge_unless_nil(base, nil), do: base
    defp merge_unless_nil(base, override), do: Map.merge(base, override)

    defp maybe_put(opts, _key, nil), do: opts
    defp maybe_put(opts, key, val), do: [{key, val} | opts]

    defp maybe_put_fallback(opts, key, val) do
      if Keyword.has_key?(opts, key), do: opts, else: maybe_put(opts, key, val)
    end
  end
end
