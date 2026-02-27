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
    - `:base_url` — the public URL of the agent endpoint (required)
    - `:agent_card_path` — path segments for the agent card endpoint
      (default: `[".well-known", "agent-card.json"]`)
    - `:json_rpc_path` — path segments for the JSON-RPC endpoint (default: `[]`)
    - `:agent_card_opts` — keyword options forwarded to `A2A.JSON.encode_agent_card/2`
    """

    @behaviour Plug
    @behaviour A2A.JSONRPC

    import Plug.Conn

    alias A2A.JSONRPC.{Error, Response}

    @impl Plug
    @spec init(keyword()) :: map()
    def init(opts) do
      %{
        agent: Keyword.fetch!(opts, :agent),
        base_url: Keyword.fetch!(opts, :base_url),
        agent_card_path: Keyword.get(opts, :agent_card_path, [".well-known", "agent-card.json"]),
        json_rpc_path: Keyword.get(opts, :json_rpc_path, []),
        agent_card_opts: Keyword.get(opts, :agent_card_opts, [])
      }
    end

    @impl Plug
    @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
    def call(%{method: "GET", path_info: path} = conn, %{agent_card_path: path} = opts) do
      serve_agent_card(conn, opts)
    end

    def call(%{method: "POST", path_info: path} = conn, %{json_rpc_path: path} = opts) do
      handle_json_rpc(conn, opts)
    end

    def call(%{path_info: path} = conn, %{agent_card_path: path}) do
      conn
      |> put_resp_header("allow", "GET")
      |> send_resp(405, "Method Not Allowed")
    end

    def call(conn, _opts) do
      send_resp(conn, 404, "Not Found")
    end

    # -- Agent card ------------------------------------------------------------

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
          Process.put(:a2a_plug_agent, opts.agent)

          try do
            case A2A.JSONRPC.handle(decoded, __MODULE__) do
              {:reply, response} ->
                send_json(conn, response)

              {:stream, "message/stream", params, id} ->
                A2A.Plug.SSE.stream_message(conn, opts.agent, params["message"], id)

              {:stream, "tasks/resubscribe", _params, id} ->
                send_json(conn, Response.error(id, Error.unsupported_operation()))
            end
          after
            Process.delete(:a2a_plug_agent)
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
    def handle_send(message, params) do
      agent = Process.get(:a2a_plug_agent)
      opts = extract_call_opts(params)

      case A2A.call(agent, message, opts) do
        {:ok, task} -> {:ok, task}
        {:error, reason} -> {:error, Error.internal_error(inspect(reason))}
      end
    end

    @impl A2A.JSONRPC
    def handle_get(task_id, _params) do
      agent = Process.get(:a2a_plug_agent)

      case GenServer.call(agent, {:get_task, task_id}) do
        {:ok, task} -> {:ok, task}
        {:error, :not_found} -> {:error, Error.task_not_found()}
      end
    end

    @impl A2A.JSONRPC
    def handle_cancel(task_id, _params) do
      agent = Process.get(:a2a_plug_agent)

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

    # -- Helpers ---------------------------------------------------------------

    defp extract_call_opts(params) do
      []
      |> maybe_put(:task_id, params["id"])
      |> maybe_put(:context_id, params["contextId"])
      |> maybe_put(:metadata, params["metadata"])
    end

    defp maybe_put(opts, _key, nil), do: opts
    defp maybe_put(opts, key, val), do: [{key, val} | opts]
  end
end
