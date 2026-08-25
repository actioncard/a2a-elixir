if Code.ensure_loaded?(Plug) do
  defmodule A2A.Transport.REST.Server do
    @moduledoc """
    REST/HTTP-JSON transport server for A2A protocol.

    Translates REST endpoints into JSON-RPC requests and dispatches them
    through `A2A.JSONRPC`, reusing the same handler pipeline as `A2A.Plug`.
    This ensures the extension pipeline and authorization callbacks are
    applied consistently regardless of transport.

    ## Usage

        plug A2A.Transport.REST.Server, agent: MyAgent, base_url: "http://localhost:8080"

    ## Options

    Accepts the same options as `A2A.Plug`:

    - `:agent` — GenServer name or pid of the agent (required)
    - `:base_url` — the public URL of the agent endpoint (required for card)
    - `:metadata` — static metadata merged into every call (default: `%{}`)
    - `:authorize_task` — optional authorization callback (see `A2A.Plug`)
    """

    import Plug.Conn

    @behaviour Plug
    @behaviour A2A.JSONRPC

    alias A2A.JSONRPC.Error

    @impl Plug
    @spec init(keyword()) :: map()
    def init(opts) do
      %{
        agent: Keyword.fetch!(opts, :agent),
        base_url: Keyword.get(opts, :base_url),
        metadata: Keyword.get(opts, :metadata, %{}),
        authorize_task: Keyword.get(opts, :authorize_task),
        agent_card_opts: Keyword.get(opts, :agent_card_opts, [])
      }
    end

    @impl Plug
    @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
    def call(conn, opts) do
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.path_info} do
        {"POST", ["v1", "message", "send"]} ->
          handle_send_message(conn, opts)

        {"GET", ["v1", "tasks", task_id]} ->
          handle_get_task(conn, opts, task_id)

        {"POST", ["v1", "tasks", task_id, "cancel"]} ->
          handle_cancel_task(conn, opts, task_id)

        {"GET", ["v1", "tasks"]} ->
          handle_list_tasks(conn, opts)

        {"GET", ["v1", "card"]} ->
          handle_get_card(conn, opts)

        _ ->
          send_error(conn, 404, "Not found")
      end
    end

    # -- Endpoint handlers -----------------------------------------------------

    defp handle_send_message(conn, opts) do
      with {:ok, body} <- read_json_body(conn),
           {:ok, message_data} <- require_field(body, "message") do
        params =
          %{"message" => message_data}
          |> put_unless_nil("metadata", body["metadata"])

        jsonrpc_request = %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "message/send",
          "params" => params
        }

        context = build_context(opts)

        case A2A.JSONRPC.handle(jsonrpc_request, __MODULE__, context) do
          {:reply, response} ->
            translate_jsonrpc_response(conn, response)

          {:stream, _method, _params, _id} ->
            send_error(conn, 501, "Streaming not supported on REST transport")
        end
      else
        {:error, :body_too_large} ->
          send_error(conn, 413, "Request body too large")

        {:error, _reason} ->
          send_error(conn, 400, "Invalid request body")
      end
    end

    defp handle_get_task(conn, opts, task_id) do
      history_length = conn.query_params["historyLength"]

      params =
        %{"id" => task_id}
        |> put_unless_nil("historyLength", parse_integer(history_length))

      dispatch_jsonrpc(conn, opts, "tasks/get", params)
    end

    defp handle_cancel_task(conn, opts, task_id) do
      dispatch_jsonrpc(conn, opts, "tasks/cancel", %{"id" => task_id})
    end

    defp handle_list_tasks(conn, opts) do
      params =
        %{}
        |> put_unless_nil("pageSize", parse_integer(conn.query_params["pageSize"]))
        |> put_unless_nil("pageToken", conn.query_params["pageToken"])

      dispatch_jsonrpc(conn, opts, "tasks/list", params)
    end

    defp handle_get_card(conn, opts) do
      case opts.base_url do
        nil ->
          send_error(conn, 500, "Server misconfigured: missing base_url")

        base_url ->
          card = GenServer.call(opts.agent, :get_agent_card)

          json =
            A2A.JSON.encode_agent_card(
              card,
              [url: base_url] ++ opts.agent_card_opts
            )

          send_json_response(conn, 200, json)
      end
    end

    defp dispatch_jsonrpc(conn, opts, method, params) do
      jsonrpc_request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => method,
        "params" => params
      }

      context = build_context(opts)

      case A2A.JSONRPC.handle(jsonrpc_request, __MODULE__, context) do
        {:reply, response} ->
          translate_jsonrpc_response(conn, response)
      end
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
        {:error, _reason} -> {:error, Error.internal_error("Message processing failed")}
      end
    end

    @impl A2A.JSONRPC
    def handle_get(task_id, params, %{agent: agent, opts: plug_opts}) do
      case GenServer.call(agent, {:get_task, task_id}) do
        {:ok, task} -> authorize_task(:get, task, params, plug_opts)
        {:error, :not_found} -> {:error, Error.task_not_found()}
      end
    end

    @impl A2A.JSONRPC
    def handle_cancel(task_id, params, %{agent: agent, opts: plug_opts}) do
      with {:ok, task} <- fetch_task(agent, task_id),
           {:ok, _task} <- authorize_task(:cancel, task, params, plug_opts) do
        case GenServer.call(agent, {:cancel, task_id}) do
          :ok ->
            fetch_task_or_error(agent, task_id)

          {:error, :not_found} ->
            {:error, Error.task_not_found()}

          {:error, _reason} ->
            {:error, Error.task_not_cancelable("Task cannot be canceled")}
        end
      else
        {:error, :not_found} -> {:error, Error.task_not_found()}
        {:error, %Error{} = error} -> {:error, error}
      end
    end

    @impl A2A.JSONRPC
    def handle_list(params, %{agent: agent, opts: plug_opts}) do
      case GenServer.call(agent, {:list_tasks, params}) do
        {:ok, result} ->
          {:ok, authorize_task_list(result, params, plug_opts)}

        {:error, :invalid_page_token} ->
          {:error, Error.invalid_params("\"pageToken\" is invalid")}

        {:error, _reason} ->
          {:error, Error.internal_error("Failed to list tasks")}
      end
    end

    # -- Private helpers -------------------------------------------------------

    defp build_context(opts) do
      %{agent: opts.agent, opts: opts}
    end

    defp fetch_task(agent, task_id) do
      case GenServer.call(agent, {:get_task, task_id}) do
        {:ok, task} -> {:ok, task}
        {:error, :not_found} -> {:error, :not_found}
      end
    end

    defp fetch_task_or_error(agent, task_id) do
      case GenServer.call(agent, {:get_task, task_id}) do
        {:ok, task} -> {:ok, task}
        {:error, :not_found} -> {:error, Error.task_not_found()}
      end
    end

    defp authorize_task(_operation, task, _params, %{authorize_task: nil}), do: {:ok, task}

    defp authorize_task(operation, task, params, plug_opts) do
      context = %{metadata: request_metadata(params, plug_opts), params: params}

      case call_authorizer(plug_opts.authorize_task, operation, task, context) do
        :ok -> {:ok, task}
        true -> {:ok, task}
        {:ok, true} -> {:ok, task}
        {:ok, _identity} -> {:ok, task}
        {:error, %Error{} = error} -> {:error, error}
        _deny -> {:error, Error.task_not_found()}
      end
    end

    defp authorize_task_list(result, _params, %{authorize_task: nil}), do: result

    defp authorize_task_list(%{tasks: tasks} = result, params, plug_opts) do
      authorized =
        Enum.filter(tasks, fn task ->
          match?({:ok, ^task}, authorize_task(:list, task, params, plug_opts))
        end)

      %{
        result
        | tasks: authorized,
          total_size: length(authorized),
          page_size: length(authorized)
      }
    end

    defp call_authorizer(fun, operation, task, context) when is_function(fun, 3) do
      fun.(operation, task, context)
    end

    defp call_authorizer(fun, operation, task, _context) when is_function(fun, 2) do
      fun.(operation, task)
    end

    defp call_authorizer({module, function}, operation, task, context) do
      apply(module, function, [operation, task, context])
    end

    defp build_call_opts(params, plug_opts) do
      metadata = request_metadata(params, plug_opts)

      []
      |> maybe_put(:task_id, params["id"])
      |> maybe_put(:context_id, params["contextId"])
      |> maybe_put(:metadata, if(metadata == %{}, do: nil, else: metadata))
    end

    defp request_metadata(params, plug_opts) do
      merge_unless_nil(plug_opts.metadata, params["metadata"])
    end

    defp merge_unless_nil(base, nil), do: base
    defp merge_unless_nil(base, override), do: Map.merge(base, override)

    defp maybe_put(opts, _key, nil), do: opts
    defp maybe_put(opts, key, val), do: [{key, val} | opts]

    defp maybe_put_fallback(opts, key, val) do
      if Keyword.has_key?(opts, key), do: opts, else: maybe_put(opts, key, val)
    end

    # -- JSON-RPC to REST response translation ---------------------------------

    defp translate_jsonrpc_response(conn, %{"result" => result}) do
      send_json_response(conn, 200, result)
    end

    defp translate_jsonrpc_response(conn, %{"error" => error}) do
      status = error_code_to_http_status(error["code"])
      send_error(conn, status, error["message"])
    end

    defp error_code_to_http_status(-32_001), do: 404
    defp error_code_to_http_status(-32_002), do: 409
    defp error_code_to_http_status(-32_602), do: 400
    defp error_code_to_http_status(-32_600), do: 400
    defp error_code_to_http_status(-32_601), do: 404
    defp error_code_to_http_status(-32_700), do: 400
    defp error_code_to_http_status(_), do: 500

    # -- Body reading / response helpers ---------------------------------------

    defp read_json_body(%{body_params: %Plug.Conn.Unfetched{}} = conn) do
      case Plug.Conn.read_body(conn) do
        {:ok, body, _conn} ->
          Jason.decode(body)

        {:more, _partial_body, _conn} ->
          {:error, :body_too_large}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp read_json_body(%{body_params: %{} = params}) do
      {:ok, params}
    end

    defp send_json_response(conn, status, data) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(data))
      |> halt()
    end

    defp send_error(conn, status, message) when is_binary(message) do
      send_json_response(conn, status, %{"error" => message})
    end

    defp require_field(map, field) when is_map(map) do
      case Map.fetch(map, field) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, {:missing_field, field}}
      end
    end

    defp require_field(_, _field), do: {:error, :invalid_body}

    defp parse_integer(nil), do: nil

    defp parse_integer(str) when is_binary(str) do
      case Integer.parse(str) do
        {int, ""} -> int
        _ -> nil
      end
    end

    defp parse_integer(int) when is_integer(int), do: int

    defp put_unless_nil(map, _key, nil), do: map
    defp put_unless_nil(map, key, val), do: Map.put(map, key, val)
  end
end
