if Code.ensure_loaded?(Plug) do
  defmodule A2A.Plug.SSE do
    @moduledoc false

    import Plug.Conn

    alias A2A.JSONRPC.{Error, Response}

    @doc """
    Streams a message/stream response as SSE events.

    Calls `A2A.stream/3` on the agent, then sends each part as an
    `ArtifactUpdate` SSE event and finishes with a terminal `StatusUpdate`
    event. Each event is a `StreamResponse` wrapper inside the JSON-RPC
    `result`.

    An agent that replies `{:message, parts}` answers out-of-band: the
    stream is a single Message event with no task snapshot and no final
    status, since no task was ever created.

    The optional `call_opts` are forwarded to `A2A.stream/3` so that
    metadata, task_id, and context_id reach the agent.
    """
    @spec stream_message(
            Plug.Conn.t(),
            GenServer.server(),
            A2A.Message.t(),
            term(),
            keyword()
          ) :: Plug.Conn.t()
    def stream_message(conn, agent, message, jsonrpc_id, call_opts \\ []) do
      case A2A.stream(agent, message, call_opts) do
        {:ok, task, enum} ->
          conn = start_sse(conn)
          conn = send_task_snapshot(conn, jsonrpc_id, task)
          stream_and_finalize(conn, jsonrpc_id, task, enum)

        {:ok, %A2A.Message{} = agent_message} ->
          conn |> start_sse() |> send_message_event(jsonrpc_id, agent_message)

        {:error, :not_found} ->
          send_jsonrpc_error(conn, jsonrpc_id, Error.task_not_found())

        {:error, :not_continuable} ->
          send_jsonrpc_error(conn, jsonrpc_id, Error.unsupported_operation())

        {:error, :message_on_task} ->
          send_jsonrpc_error(
            conn,
            jsonrpc_id,
            Error.invalid_agent_response("Message reply to a task-scoped request")
          )

        {:error, reason} ->
          send_jsonrpc_error(conn, jsonrpc_id, Error.internal_error(inspect(reason)))
      end
    end

    defp send_jsonrpc_error(conn, jsonrpc_id, error) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(Response.error(jsonrpc_id, error)))
    end

    defp start_sse(conn) do
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)
    end

    # Strip the :stream key from metadata — it holds the raw enumerable
    # function ref which is not JSON-serializable.
    defp send_task_snapshot(conn, jsonrpc_id, task) do
      clean = %{task | metadata: Map.delete(task.metadata, :stream)}
      {:ok, encoded} = A2A.JSON.encode_stream_response(clean)
      send_event(conn, jsonrpc_id, encoded)
    end

    defp send_message_event(conn, jsonrpc_id, message) do
      {:ok, encoded} = A2A.JSON.encode_stream_response(message)

      case send_event(conn, jsonrpc_id, encoded) do
        {:error, conn} -> conn
        conn -> conn
      end
    end

    defp stream_and_finalize(conn, jsonrpc_id, task, enum) do
      conn = stream_parts(conn, jsonrpc_id, task, enum)
      send_final_status(conn, jsonrpc_id, task, :completed)
    rescue
      e ->
        send_final_status(conn, jsonrpc_id, task, :failed, Exception.message(e))
    end

    defp stream_parts(conn, jsonrpc_id, task, enum) do
      Enum.reduce_while(enum, conn, fn part, conn ->
        artifact = A2A.Artifact.new([part])

        event =
          A2A.Event.ArtifactUpdate.new(task.id, artifact, context_id: task.context_id)

        {:ok, encoded} = A2A.JSON.encode_stream_response(event)

        case send_event(conn, jsonrpc_id, encoded) do
          {:error, conn} -> {:halt, conn}
          conn -> {:cont, conn}
        end
      end)
    end

    defp send_final_status(conn, jsonrpc_id, task, state, message_text \\ nil) do
      status_msg =
        if message_text,
          do: A2A.Message.new_agent(message_text),
          else: nil

      event =
        A2A.Event.StatusUpdate.new(
          task.id,
          A2A.Task.Status.new(state, status_msg),
          context_id: task.context_id,
          final: true
        )

      {:ok, encoded} = A2A.JSON.encode_stream_response(event)

      case send_event(conn, jsonrpc_id, encoded) do
        {:error, conn} -> conn
        conn -> conn
      end
    end

    defp send_event(conn, jsonrpc_id, encoded_result) do
      payload = Response.success(jsonrpc_id, encoded_result)
      data = "data: #{Jason.encode!(payload)}\n\n"

      case chunk(conn, data) do
        {:ok, conn} -> conn
        {:error, :closed} -> {:error, conn}
      end
    end
  end
end
