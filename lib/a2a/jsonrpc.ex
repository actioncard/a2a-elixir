defmodule A2A.JSONRPC do
  @moduledoc """
  Transport-agnostic JSON-RPC 2.0 dispatch layer for the A2A protocol.

  Defines a handler behaviour and a `handle/3` function that parses JSON-RPC
  envelopes, validates params, and dispatches to the handler module.

  ## Handler behaviour

  Three callbacks are required — every A2A server answers these methods:

      defmodule MyHandler do
        @behaviour A2A.JSONRPC

        @impl true
        def handle_send(message, params, context) do
          # process the message, return {:ok, task}, {:ok, message}, or
          # {:error, error} — `SendMessageResponse` is a Task/Message oneof
        end

        @impl true
        def handle_get(task_id, params, context) do
          # look up the task
        end

        @impl true
        def handle_cancel(task_id, params, context) do
          # cancel the task
        end
      end

  Five more are optional, and each has a defined answer when absent:

  - `c:handle_list/2` serves `tasks/list`. Without it that method answers
    `-32601`, method not found.
  - `c:handle_set_push_config/3`, `c:handle_get_push_config/4`,
    `c:handle_list_push_configs/3` and `c:handle_delete_push_config/4` serve
    the four `tasks/pushNotificationConfig/*` methods. Without them those
    answer `-32003`, push notifications not supported.

  Presence is checked per request with `Code.ensure_loaded?/1` and
  `function_exported?/3`, so a handler implementing none of the optional
  callbacks behaves exactly as it did before they existed.

  ## Dispatching

      case A2A.JSONRPC.handle(decoded_body, MyHandler) do
        {:reply, response_map} -> send_json(response_map)
        {:stream, method, params, id} -> start_sse(method, params, id)
      end

  The third argument to `handle/3` is a context map, threaded unchanged to
  every callback, which transports use to pass per-request data.
  """

  alias A2A.JSONRPC.{Error, Request, Response}

  # v0.3.0 PascalCase method names → internal slash-style names
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
              {:ok, A2A.Task.t() | A2A.Message.t()} | {:error, Error.t()}

  @doc "Called for `tasks/get` requests."
  @callback handle_get(task_id :: String.t(), params :: map(), context :: map()) ::
              {:ok, A2A.Task.t()} | {:error, Error.t()}

  @doc "Called for `tasks/cancel` requests."
  @callback handle_cancel(task_id :: String.t(), params :: map(), context :: map()) ::
              {:ok, A2A.Task.t()} | {:error, Error.t()}

  @doc "Called for `tasks/list` requests. Optional."
  @callback handle_list(params :: map(), context :: map()) ::
              {:ok, map()} | {:error, Error.t()}

  @doc "Called for `tasks/pushNotificationConfig/set` requests. Optional."
  @callback handle_set_push_config(
              A2A.PushNotificationConfig.t(),
              params :: map(),
              context :: map()
            ) :: {:ok, A2A.PushNotificationConfig.t()} | {:error, Error.t()}

  @doc "Called for `tasks/pushNotificationConfig/get` requests. Optional."
  @callback handle_get_push_config(
              task_id :: String.t(),
              config_id :: String.t(),
              params :: map(),
              context :: map()
            ) :: {:ok, A2A.PushNotificationConfig.t()} | {:error, Error.t()}

  @doc "Called for `tasks/pushNotificationConfig/list` requests. Optional."
  @callback handle_list_push_configs(task_id :: String.t(), params :: map(), context :: map()) ::
              {:ok, [A2A.PushNotificationConfig.t()]} | {:error, Error.t()}

  @doc "Called for `tasks/pushNotificationConfig/delete` requests. Optional."
  @callback handle_delete_push_config(
              task_id :: String.t(),
              config_id :: String.t(),
              params :: map(),
              context :: map()
            ) :: :ok | {:error, Error.t()}

  @optional_callbacks handle_list: 2,
                      handle_set_push_config: 3,
                      handle_get_push_config: 4,
                      handle_list_push_configs: 3,
                      handle_delete_push_config: 4

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
    history_length = Request.history_length(req.params["configuration"] || %{})

    with {:ok, message} <- decode_message(req.params),
         {:ok, result} <-
           safe_call(fn -> handler.handle_send(message, req.params, ctx) end),
         {:ok, encoded} <- encode_send_result(result, history_length) do
      {:reply, Response.success(req.id, encoded)}
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
    history_length = Request.history_length(req.params)

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
    if exports?(handler, :handle_list, 2) do
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

  defp dispatch(%Request{method: "tasks/pushNotificationConfig/set"} = req, handler, ctx) do
    if exports?(handler, :handle_set_push_config, 3) do
      with {:ok, config} <- decode_push_config(req.params),
           {:ok, stored} <-
             safe_call(fn -> handler.handle_set_push_config(config, req.params, ctx) end),
           {:ok, encoded} <- A2A.JSON.encode(stored) do
        {:reply, Response.success(req.id, encoded)}
      else
        {:error, %Error{} = error} -> {:reply, Response.error(req.id, error)}
      end
    else
      {:reply, Response.error(req.id, Error.push_notification_not_supported())}
    end
  end

  defp dispatch(%Request{method: "tasks/pushNotificationConfig/get"} = req, handler, ctx) do
    if exports?(handler, :handle_get_push_config, 4) do
      task_id = push_task_id(req.params)
      config_id = req.params["id"]

      with {:ok, config} <-
             safe_call(fn ->
               handler.handle_get_push_config(task_id, config_id, req.params, ctx)
             end),
           {:ok, encoded} <- A2A.JSON.encode(config) do
        {:reply, Response.success(req.id, encoded)}
      else
        {:error, %Error{} = error} -> {:reply, Response.error(req.id, error)}
      end
    else
      {:reply, Response.error(req.id, Error.push_notification_not_supported())}
    end
  end

  defp dispatch(%Request{method: "tasks/pushNotificationConfig/list"} = req, handler, ctx) do
    if exports?(handler, :handle_list_push_configs, 3) do
      task_id = push_task_id(req.params)

      case safe_call(fn -> handler.handle_list_push_configs(task_id, req.params, ctx) end) do
        {:ok, configs} ->
          encoded = Enum.map(configs, &A2A.JSON.encode!/1)
          {:reply, Response.success(req.id, %{"configs" => encoded})}

        {:error, %Error{} = error} ->
          {:reply, Response.error(req.id, error)}
      end
    else
      {:reply, Response.error(req.id, Error.push_notification_not_supported())}
    end
  end

  defp dispatch(%Request{method: "tasks/pushNotificationConfig/delete"} = req, handler, ctx) do
    if exports?(handler, :handle_delete_push_config, 4) do
      task_id = push_task_id(req.params)
      config_id = req.params["id"]

      # `safe_call/1` only understands ok/error tuples; delete answers a bare
      # `:ok`, so normalize inside the closure to keep its rescue in play.
      result =
        safe_call(fn ->
          case handler.handle_delete_push_config(task_id, config_id, req.params, ctx) do
            :ok -> {:ok, %{}}
            other -> other
          end
        end)

      case result do
        {:ok, _} -> {:reply, Response.success(req.id, %{})}
        {:error, %Error{} = error} -> {:reply, Response.error(req.id, error)}
      end
    else
      {:reply, Response.error(req.id, Error.push_notification_not_supported())}
    end
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

  # The spec and REST binding use `taskId`; the TCK and proto clients send
  # `task_id`. Both are accepted, as they already are for `historyLength`.
  defp push_task_id(params), do: params["taskId"] || params["task_id"]

  # v1.0 sends the config flat on params; v0.3 nests it under
  # `pushNotificationConfig`. `taskId` always lives on params either way.
  defp decode_push_config(params) do
    source =
      case Map.get(params, "pushNotificationConfig") do
        config when is_map(config) -> config
        _ -> params
      end

    source = Map.put(source, "taskId", push_task_id(params))

    case A2A.JSON.decode(source, :push_notification_config) do
      {:ok, _config} = ok -> ok
      {:error, reason} -> {:error, Error.invalid_params(inspect(reason))}
    end
  end

  defp decode_message(params) do
    case A2A.JSON.decode(params["message"], :message) do
      {:ok, _message} = ok -> ok
      {:error, reason} -> {:error, Error.invalid_params(inspect(reason))}
    end
  end

  # `SendMessageResponse` is a Task/Message oneof. `historyLength` and the
  # `:stream` metadata key are task-only — a Message has neither field.
  defp encode_send_result(%A2A.Task{} = task, history_length) do
    with {:ok, encoded} <-
           task
           |> A2A.Task.truncate_history(history_length)
           |> A2A.Task.strip_stream_metadata()
           |> A2A.JSON.encode() do
      {:ok, %{"task" => encoded}}
    end
  end

  defp encode_send_result(%A2A.Message{} = message, _history_length) do
    with {:ok, encoded} <- A2A.JSON.encode(message) do
      {:ok, %{"message" => encoded}}
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

  # `function_exported?/3` answers false for a module that has not been loaded
  # yet, which under lazy loading silently downgrades a supported method to
  # "unsupported". Force the load before asking.
  defp exports?(handler, fun, arity) do
    Code.ensure_loaded?(handler) and function_exported?(handler, fun, arity)
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
