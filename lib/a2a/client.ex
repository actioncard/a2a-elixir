if Code.ensure_loaded?(Req) do
  defmodule A2A.Client do
    @moduledoc """
    HTTP client for consuming remote A2A agents.

    Provides discovery, synchronous messaging, SSE streaming, and task
    management using the A2A JSON-RPC protocol over HTTP.

    ## Quick Start

        # Discover an agent
        {:ok, card} = A2A.Client.discover("https://agent.example.com")

        # Create a client and send a message
        client = A2A.Client.new(card)
        {:ok, task} = A2A.Client.send_message(client, "Hello!")

        # Stream a response
        {:ok, stream} = A2A.Client.stream_message(client, "Count to 5")
        Enum.each(stream, &IO.inspect/1)

    ## Convenience Overloads

    All functions that accept a `%A2A.Client{}` also accept a URL string
    or `%A2A.AgentCard{}`:

        {:ok, task} = A2A.Client.send_message("https://agent.example.com", "Hello!")
        {:ok, task} = A2A.Client.send_message(card, "Hello!")

    ## Options

    Functions that send messages accept these options:

    - `:task_id` — continue an existing task (multi-turn)
    - `:context_id` — set the context ID
    - `:configuration` — `MessageSendConfiguration` map
    - `:metadata` — arbitrary metadata map
    - `:headers` — additional HTTP headers
    - `:timeout` — HTTP request timeout in ms

    ## Method Style

    By default the client sends v1.0 PascalCase method names (e.g.
    `SendMessage`). To communicate with a v0.3 server, pass
    `method_style: :legacy` when creating the client:

        client = A2A.Client.new(url, method_style: :legacy)
    """

    alias A2A.JSONRPC.Error

    @type target :: t() | A2A.AgentCard.t() | String.t()

    @type t :: %__MODULE__{
            url: String.t(),
            req: Req.Request.t(),
            method_style: :v1 | :legacy
          }

    defstruct [:url, :req, method_style: :legacy]

    @doc """
    Creates a new client struct.

    Accepts a URL string or `%A2A.AgentCard{}`. Options are forwarded to
    `Req.new/1` for customizing the HTTP client (headers, timeouts, etc.).

    ## Options

    - `:method_style` — `:legacy` (default, slash-style for v0.3 compat) or `:v1` (PascalCase for v1.0 servers)
    - All other options are forwarded to `Req.new/1`

    ## Examples

        client = A2A.Client.new("https://agent.example.com")
        client = A2A.Client.new(card, headers: [{"authorization", "Bearer token"}])
        client = A2A.Client.new(url, method_style: :legacy)
    """
    @spec new(A2A.AgentCard.t() | String.t(), keyword()) :: t()
    def new(url_or_card, opts \\ [])

    def new(%A2A.AgentCard{url: url}, opts) do
      new(url, opts)
    end

    def new(url, opts) when is_binary(url) do
      method_style = Keyword.get(opts, :method_style, :legacy)

      {req_opts, _rest} =
        Keyword.split(opts, [:headers, :connect_options, :retry, :plug])

      req =
        Req.new(
          Keyword.merge(
            [base_url: url, headers: [{"content-type", "application/json"}]],
            req_opts
          )
        )

      %__MODULE__{url: url, req: req, method_style: method_style}
    end

    @doc """
    Discovers an agent by fetching its agent card.

    Sends `GET /.well-known/agent-card.json` and decodes the response
    into an `%A2A.AgentCard{}`.

    ## Options

    - `:headers` — additional HTTP headers
    - `:timeout` — HTTP request timeout in ms
    - `:agent_card_path` — custom discovery path
      (default: `"/.well-known/agent-card.json"`)

    ## Examples

        {:ok, card} = A2A.Client.discover("https://agent.example.com")
        card.name #=> "my-agent"
    """
    @spec discover(String.t(), keyword()) :: {:ok, A2A.AgentCard.t()} | {:error, term()}
    def discover(base_url, opts \\ []) do
      path = Keyword.get(opts, :agent_card_path, "/.well-known/agent-card.json")
      req_opts = take_req_opts(opts)

      base_opts = [base_url: base_url]

      req = Req.new(Keyword.merge(base_opts, req_opts))

      case Req.get(req, url: path) do
        {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
          A2A.JSON.decode_agent_card(body)

        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          with {:ok, decoded} <- Jason.decode(body) do
            A2A.JSON.decode_agent_card(decoded)
          end

        {:ok, %Req.Response{status: status}} ->
          {:error, {:unexpected_status, status}}

        {:error, _} = error ->
          error
      end
    end

    @doc """
    Sends a message to an agent via `message/send`.

    Returns `{:ok, task}` on success or `{:error, reason}` on failure.
    The message can be a string, an `%A2A.Message{}`, or a list of parts.

    ## Options

    - `:task_id` — continue an existing task
    - `:context_id` — set the context ID
    - `:configuration` — `MessageSendConfiguration` map
    - `:metadata` — arbitrary metadata map
    - `:headers` — additional HTTP headers
    - `:timeout` — HTTP request timeout in ms

    ## Examples

        {:ok, task} = A2A.Client.send_message(client, "Hello!")
        {:ok, task} = A2A.Client.send_message(client, "More info", task_id: task.id)
    """
    @spec send_message(target(), A2A.Message.t() | String.t(), keyword()) ::
            {:ok, A2A.Task.t()} | {:error, term()}
    def send_message(target, message, opts \\ []) do
      client = ensure_client(target)
      {params, req_opts} = build_send_params(message, opts)
      method = resolve_method("message/send", client.method_style)
      body = jsonrpc_request(method, params)

      case post(client, body, req_opts) do
        {:ok, response} -> decode_jsonrpc_result(response, :task)
        {:error, _} = error -> error
      end
    end

    @doc """
    Sends a message and returns a stream of decoded SSE events.

    Uses `message/stream` to receive server-sent events. Returns
    `{:ok, stream}` where the stream yields decoded structs
    (`%A2A.Task{}`, `%A2A.Event.StatusUpdate{}`, `%A2A.Event.ArtifactUpdate{}`,
    or `%A2A.Message{}`).

    ## Options

    Same as `send_message/3`.

    ## Examples

        {:ok, stream} = A2A.Client.stream_message(client, "Count to 5")
        Enum.each(stream, fn
          %A2A.Event.StatusUpdate{final: true} -> :done
          event -> IO.inspect(event)
        end)
    """
    @spec stream_message(target(), A2A.Message.t() | String.t(), keyword()) ::
            {:ok, Enumerable.t()} | {:error, term()}
    def stream_message(target, message, opts \\ []) do
      client = ensure_client(target)
      {params, req_opts} = build_send_params(message, opts)
      method = resolve_method("message/stream", client.method_style)
      body = jsonrpc_request(method, params)

      json_body = Jason.encode!(body)
      req = merge_req_opts(client.req, req_opts)

      case Req.post(req,
             body: json_body,
             headers: [{"accept", "text/event-stream"}],
             into: :self
           ) do
        {:ok, %Req.Response{status: 200, body: async}} ->
          stream = build_sse_stream(async)
          {:ok, stream}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:unexpected_status, status}}

        {:error, _} = error ->
          error
      end
    end

    @doc """
    Retrieves a task by ID via `tasks/get`.

    ## Options

    - `:history_length` — number of history entries to include
    - `:headers` — additional HTTP headers
    - `:timeout` — HTTP request timeout in ms

    ## Examples

        {:ok, task} = A2A.Client.get_task(client, "tsk-abc123")
    """
    @spec get_task(target(), String.t(), keyword()) ::
            {:ok, A2A.Task.t()} | {:error, term()}
    def get_task(target, task_id, opts \\ []) do
      client = ensure_client(target)
      req_opts = take_req_opts(opts)

      params =
        %{"id" => task_id}
        |> put_opt("historyLength", opts[:history_length])

      method = resolve_method("tasks/get", client.method_style)
      body = jsonrpc_request(method, params)

      case post(client, body, req_opts) do
        {:ok, response} -> decode_jsonrpc_result(response, :task)
        {:error, _} = error -> error
      end
    end

    @doc """
    Cancels a task by ID via `tasks/cancel`.

    ## Options

    - `:headers` — additional HTTP headers
    - `:timeout` — HTTP request timeout in ms

    ## Examples

        {:ok, task} = A2A.Client.cancel_task(client, "tsk-abc123")
    """
    @spec cancel_task(target(), String.t(), keyword()) ::
            {:ok, A2A.Task.t()} | {:error, term()}
    def cancel_task(target, task_id, opts \\ []) do
      client = ensure_client(target)
      req_opts = take_req_opts(opts)
      params = %{"id" => task_id}
      method = resolve_method("tasks/cancel", client.method_style)
      body = jsonrpc_request(method, params)

      case post(client, body, req_opts) do
        {:ok, response} -> decode_jsonrpc_result(response, :task)
        {:error, _} = error -> error
      end
    end

    # -------------------------------------------------------------------
    # Private — Method name mapping
    # -------------------------------------------------------------------

    # v1.0 PascalCase equivalents for legacy slash-style method names
    @v1_method_names %{
      "message/send" => "SendMessage",
      "message/stream" => "SendStreamingMessage",
      "tasks/get" => "GetTask",
      "tasks/cancel" => "CancelTask",
      "tasks/list" => "ListTasks",
      "tasks/resubscribe" => "SubscribeToTask",
      "tasks/pushNotificationConfig/set" => "CreateTaskPushNotificationConfig",
      "tasks/pushNotificationConfig/get" => "GetTaskPushNotificationConfig",
      "tasks/pushNotificationConfig/list" => "ListTaskPushNotificationConfigs",
      "tasks/pushNotificationConfig/delete" => "DeleteTaskPushNotificationConfig",
      "agent/getAuthenticatedExtendedCard" => "GetExtendedAgentCard"
    }

    defp resolve_method(method, :v1), do: Map.get(@v1_method_names, method, method)
    defp resolve_method(method, :legacy), do: method

    # -------------------------------------------------------------------
    # Private — Request building
    # -------------------------------------------------------------------

    defp jsonrpc_request(method, params) do
      %{
        "jsonrpc" => "2.0",
        "id" => generate_id(),
        "method" => method,
        "params" => params
      }
    end

    defp generate_id do
      System.unique_integer([:positive, :monotonic])
    end

    defp build_send_params(message, opts) do
      req_opts = take_req_opts(opts)
      msg = normalize_message(message)
      {:ok, encoded_msg} = A2A.JSON.encode(msg)

      params =
        %{"message" => encoded_msg}
        |> put_opt("id", opts[:task_id])
        |> put_opt("contextId", opts[:context_id])
        |> put_opt("configuration", encode_configuration(opts[:configuration]))
        |> put_opt("metadata", opts[:metadata])

      {params, req_opts}
    end

    defp normalize_message(%A2A.Message{} = msg), do: msg

    defp normalize_message(text) when is_binary(text) do
      A2A.Message.new_user(text)
    end

    defp encode_configuration(nil), do: nil

    defp encode_configuration(config) when is_map(config) do
      A2A.JSON.encode_known_keys(config, [
        {"acceptedOutputModes", :accepted_output_modes},
        {"blocking", :blocking},
        {"historyLength", :history_length}
      ])
    end

    defp put_opt(map, _key, nil), do: map
    defp put_opt(map, key, value), do: Map.put(map, key, value)

    # -------------------------------------------------------------------
    # Private — HTTP helpers
    # -------------------------------------------------------------------

    defp post(client, body, req_opts) do
      json_body = Jason.encode!(body)
      req = merge_req_opts(client.req, req_opts)
      Req.post(req, body: json_body)
    end

    defp merge_req_opts(req, []), do: req

    defp merge_req_opts(req, opts) do
      Enum.reduce(opts, req, fn
        {:headers, headers}, req -> Req.merge(req, headers: headers)
        {:timeout, timeout}, req -> Req.merge(req, receive_timeout: timeout)
        {:plug, plug}, req -> Req.merge(req, plug: plug)
        _, req -> req
      end)
    end

    defp take_req_opts(opts) do
      Keyword.take(opts, [:headers, :timeout, :plug])
    end

    defp ensure_client(%__MODULE__{} = client), do: client
    defp ensure_client(%A2A.AgentCard{} = card), do: new(card)
    defp ensure_client(url) when is_binary(url), do: new(url)

    # -------------------------------------------------------------------
    # Private — Response decoding
    # -------------------------------------------------------------------

    defp decode_jsonrpc_result(%Req.Response{body: body}, type)
         when is_map(body) do
      decode_jsonrpc_body(body, type)
    end

    defp decode_jsonrpc_result(%Req.Response{body: body}, type)
         when is_binary(body) do
      case Jason.decode(body) do
        {:ok, decoded} -> decode_jsonrpc_body(decoded, type)
        {:error, _} = error -> error
      end
    end

    defp decode_jsonrpc_body(%{"error" => error_map}, _type) do
      {:error,
       %Error{
         code: error_map["code"],
         message: error_map["message"],
         data: error_map["data"]
       }}
    end

    # SendMessageResult wrapper: {"task": Task} or {"message": Message}
    defp decode_jsonrpc_body(%{"result" => %{"task" => task}}, :task) do
      A2A.JSON.decode(task, :task)
    end

    defp decode_jsonrpc_body(%{"result" => result}, type) do
      A2A.JSON.decode(result, type)
    end

    defp decode_jsonrpc_body(body, _type) do
      {:error, {:unexpected_body, body}}
    end

    # -------------------------------------------------------------------
    # Private — SSE streaming
    # -------------------------------------------------------------------

    defp build_sse_stream(async) do
      async
      |> Stream.transform(A2A.Client.SSE.new(), fn chunk, sse_state ->
        {events, new_sse} = A2A.Client.SSE.feed(sse_state, chunk)
        decoded = decode_sse_events(events)
        {decoded, new_sse}
      end)
    end

    defp decode_sse_events(events) do
      Enum.flat_map(events, fn
        %{"result" => result} ->
          case A2A.JSON.decode(result, :event) do
            {:ok, decoded} -> [decoded]
            {:error, _} -> []
          end

        _other ->
          []
      end)
    end
  end
end
