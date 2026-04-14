defmodule A2A.JSONRPC do
  @moduledoc """
  Transport-agnostic JSON-RPC 2.0 dispatch layer for the A2A protocol.

  Defines a handler behaviour with three callbacks and a `handle/2` function
  that parses JSON-RPC envelopes, validates params, and dispatches to the
  handler module.

  ## Handler behaviour

  Implement the three callbacks to handle A2A methods:

      defmodule MyHandler do
        @behaviour A2A.JSONRPC

        @impl true
        def handle_send(message, params) do
          # process the message, return {:ok, task} or {:error, error}
        end

        @impl true
        def handle_get(task_id, params) do
          # look up the task
        end

        @impl true
        def handle_cancel(task_id, params) do
          # cancel the task
        end
      end

  ## Dispatching

      case A2A.JSONRPC.handle(decoded_body, MyHandler) do
        {:reply, response_map} -> send_json(response_map)
        {:stream, method, params, id} -> start_sse(method, params, id)
      end
  """

  alias A2A.JSONRPC.{Error, Request, Response}

  # v1.0 PascalCase method names → internal slash-style names
  @method_aliases %{
    "SendMessage" => "message/send",
    "SendStreamingMessage" => "message/stream",
    "GetTask" => "tasks/get",
    "CancelTask" => "tasks/cancel",
    "SubscribeToTask" => "tasks/resubscribe",
    "ListTasks" => "tasks/list",
    "GetExtendedAgentCard" => "agent/getAuthenticatedExtendedCard",
    "CreateTaskPushNotificationConfig" => "tasks/pushNotificationConfig/set",
    "GetTaskPushNotificationConfig" => "tasks/pushNotificationConfig/get",
    "ListTaskPushNotificationConfigs" => "tasks/pushNotificationConfig/list",
    "DeleteTaskPushNotificationConfig" => "tasks/pushNotificationConfig/delete"
  }

  @type result ::
          {:reply, map()}
          | {:stream, String.t(), map(), String.t() | integer() | nil}

  @doc "Called for `message/send` and `message/stream` requests."
  @callback handle_send(A2A.Message.t(), params :: map(), context :: map()) ::
              {:ok, A2A.Task.t()} | {:error, Error.t()}

  @doc "Called for `tasks/get` requests."
  @callback handle_get(task_id :: String.t(), params :: map(), context :: map()) ::
              {:ok, A2A.Task.t()} | {:error, Error.t()}

  @doc "Called for `tasks/cancel` requests."
  @callback handle_cancel(task_id :: String.t(), params :: map(), context :: map()) ::
              {:ok, A2A.Task.t()} | {:error, Error.t()}

  @doc "Called for `tasks/list` requests. Optional."
  @callback handle_list(params :: map(), context :: map()) ::
              {:ok, map()} | {:error, Error.t()}

  @optional_callbacks handle_list: 2

  @doc """
  Parses a JSON-RPC 2.0 request map and dispatches to the handler.

  An optional `context` map is threaded through to every handler
  callback, letting transports like `A2A.Plug` pass per-request data
  (agent pid, metadata, etc.) without the process dictionary.

  Returns `{:reply, response_map}` for synchronous methods, or
  `{:stream, method, params, id}` for streaming methods.
  """
  @spec handle(map(), module(), map()) :: result()
  def handle(raw, handler, context \\ %{}) do
    with {:ok, request} <- Request.parse(raw),
         request = normalize_method(request),
         :ok <- Request.validate_params(request) do
      dispatch(request, handler, context)
    else
      {:error, %Error{} = error} ->
        id = extract_id(raw)
        {:reply, Response.error(id, error)}
    end
  end

  # -- dispatch --------------------------------------------------------------

  defp dispatch(%Request{method: "message/send"} = req, handler, ctx) do
    with {:ok, message} <- decode_message(req.params),
         {:ok, task} <-
           safe_call(fn -> handler.handle_send(message, req.params, ctx) end),
         {:ok, encoded} <- A2A.JSON.encode(A2A.Task.strip_stream_metadata(task)) do
      {:reply, Response.success(req.id, %{"task" => encoded})}
    else
      {:error, %Error{} = error} -> {:reply, Response.error(req.id, error)}
    end
  end

  defp dispatch(%Request{method: "message/stream"} = req, _handler, _ctx) do
    case decode_message(req.params) do
      {:ok, message} ->
        params = Map.put(req.params, "message", message)
        {:stream, "message/stream", params, req.id}

      {:error, %Error{} = error} ->
        {:reply, Response.error(req.id, error)}
    end
  end

  defp dispatch(%Request{method: "tasks/get"} = req, handler, ctx) do
    task_id = req.params["id"]
    history_length = req.params["historyLength"]

    with {:ok, task} <-
           safe_call(fn -> handler.handle_get(task_id, req.params, ctx) end),
         task =
           task
           |> A2A.Task.truncate_history(history_length)
           |> A2A.Task.strip_stream_metadata(),
         {:ok, encoded} <- A2A.JSON.encode(task) do
      {:reply, Response.success(req.id, encoded)}
    else
      {:error, %Error{} = error} -> {:reply, Response.error(req.id, error)}
    end
  end

  defp dispatch(%Request{method: "tasks/cancel"} = req, handler, ctx) do
    task_id = req.params["id"]

    with {:ok, task} <-
           safe_call(fn -> handler.handle_cancel(task_id, req.params, ctx) end),
         {:ok, encoded} <- A2A.JSON.encode(A2A.Task.strip_stream_metadata(task)) do
      {:reply, Response.success(req.id, encoded)}
    else
      {:error, %Error{} = error} -> {:reply, Response.error(req.id, error)}
    end
  end

  defp dispatch(%Request{method: "tasks/list"} = req, handler, ctx) do
    if function_exported?(handler, :handle_list, 2) do
      case safe_call(fn -> handler.handle_list(req.params, ctx) end) do
        {:ok, result} -> {:reply, Response.success(req.id, encode_list_result(result))}
        {:error, %Error{} = error} -> {:reply, Response.error(req.id, error)}
      end
    else
      {:reply, Response.error(req.id, Error.method_not_found(req.method))}
    end
  end

  defp dispatch(%Request{method: "tasks/resubscribe"} = req, _handler, _ctx) do
    {:stream, "tasks/resubscribe", req.params, req.id}
  end

  defp dispatch(%Request{method: "tasks/pushNotificationConfig/" <> _} = req, _, _) do
    {:reply, Response.error(req.id, Error.push_notification_not_supported())}
  end

  defp dispatch(
         %Request{method: "agent/getAuthenticatedExtendedCard"} = req,
         _handler,
         _ctx
       ) do
    {:reply, Response.error(req.id, Error.unsupported_operation())}
  end

  defp dispatch(%Request{} = req, _handler, _ctx) do
    {:reply, Response.error(req.id, Error.method_not_found(req.method))}
  end

  # -- helpers ---------------------------------------------------------------

  defp decode_message(params) do
    case A2A.JSON.decode(params["message"], :message) do
      {:ok, _message} = ok -> ok
      {:error, reason} -> {:error, Error.invalid_params(inspect(reason))}
    end
  end

  defp encode_list_result(%{tasks: tasks} = result) do
    encoded_tasks =
      Enum.map(tasks, fn task ->
        task |> A2A.Task.strip_stream_metadata() |> A2A.JSON.encode!()
      end)

    %{
      "tasks" => encoded_tasks,
      "totalSize" => result.total_size,
      "pageSize" => result.page_size,
      "nextPageToken" => result.next_page_token
    }
  end

  defp safe_call(fun) do
    case fun.() do
      {:ok, _} = ok -> ok
      {:error, %Error{}} = err -> err
    end
  rescue
    e -> {:error, Error.internal_error(Exception.message(e))}
  end

  defp normalize_method(%Request{method: method} = request) do
    case Map.get(@method_aliases, method) do
      nil -> request
      canonical -> %{request | method: canonical}
    end
  end

  defp extract_id(%{"id" => id}) when is_binary(id) or is_integer(id), do: id
  defp extract_id(_), do: nil
end
