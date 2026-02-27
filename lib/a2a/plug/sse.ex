if Code.ensure_loaded?(Plug) do
  defmodule A2A.Plug.SSE do
    @moduledoc false

    import Plug.Conn

    alias A2A.JSONRPC.{Error, Response}

    @doc """
    Streams a message/stream response as SSE events.

    Calls `A2A.stream/3` on the agent, then sends each part as an
    `ArtifactUpdate` SSE event and finishes with a `StatusUpdate`
    event where `final: true`.
    """
    @spec stream_message(Plug.Conn.t(), GenServer.server(), A2A.Message.t(), term()) ::
            Plug.Conn.t()
    def stream_message(conn, agent, message, jsonrpc_id) do
      case A2A.stream(agent, message) do
        {:ok, task, enum} ->
          conn = start_sse(conn)
          conn = send_task_snapshot(conn, jsonrpc_id, task)
          stream_and_finalize(conn, jsonrpc_id, task, enum)

        {:error, reason} ->
          error = Error.internal_error(inspect(reason))

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(Response.error(jsonrpc_id, error)))
      end
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
      {:ok, encoded} = A2A.JSON.encode(clean)
      send_event(conn, jsonrpc_id, encoded)
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

        {:ok, encoded} = A2A.JSON.encode(event)

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

      {:ok, encoded} = A2A.JSON.encode(event)

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
