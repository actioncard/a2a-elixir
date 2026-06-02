if Code.ensure_loaded?(Plug) do
  defmodule A2A.Transport.REST.Server do
    @moduledoc """
    REST/HTTP-JSON transport server for A2A protocol.

    Provides REST endpoints that receive direct HTTP calls (no JSON-RPC wrapper).
    Compatible with Python/Go REST transport implementations.

    ## Usage

    Add to your Plug pipeline:

        plug A2A.Transport.REST.Server, agent_handler: MyApp.Agent

    Or use in Phoenix router:

        scope "/", MyApp do
          forward "/v1", A2A.Transport.REST.Server, agent_handler: MyApp.Agent
        end
    """

    import Plug.Conn

    @behaviour Plug

    @doc """
    Initialize the REST server with agent handler.
    """
    def init(opts) do
      agent_handler = Keyword.fetch!(opts, :agent_handler)
      %{agent_handler: agent_handler}
    end

    @doc """
    Handle REST endpoints for A2A protocol.
    """
    def call(conn, opts) do
      %{agent_handler: agent_handler} = opts

      # Fetch query parameters
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.path_info} do
        {"POST", ["v1", "message", "send"]} ->
          handle_send_message(conn, agent_handler)

        {"POST", ["v1", "message", "stream"]} ->
          handle_send_message_streaming(conn, agent_handler)

        {"GET", ["v1", "messages"]} ->
          handle_poll_messages(conn, agent_handler)

        {"POST", ["v1", "agents"]} ->
          handle_register_agent(conn, agent_handler)

        {"GET", ["v1", "agents", agent_id]} ->
          handle_get_agent(conn, agent_handler, agent_id)

        {"GET", ["v1", "card"]} ->
          handle_get_card(conn, agent_handler)

        {"GET", ["v1", "tasks", task_id]} ->
          handle_get_task(conn, agent_handler, task_id)

        {"POST", ["v1", "tasks", task_id, "cancel"]} ->
          handle_cancel_task(conn, agent_handler, task_id)

        _ ->
          send_error(conn, 404, "Endpoint not found")
      end
    end

    # Endpoint handlers

    defp handle_send_message(conn, agent_handler) do
      with {:ok, body} <- read_json_body(conn),
           %{"message" => message_data} <- body,
           %{"agent_card" => agent_card_data} <- body,
           {:ok, message} <- A2A.JSON.decode(message_data, :message),
           {:ok, agent_card} <- A2A.JSON.decode_agent_card(agent_card_data),
           {:ok, result} <- agent_handler.handle_message(message, agent_card) do
        response = %{
          message_id: generate_message_id(),
          result: result
        }

        send_json_response(conn, 200, response)
      else
        {:error, reason} ->
          send_error(conn, 400, "Bad request: #{inspect(reason)}")

        error ->
          send_error(conn, 500, "Internal error: #{inspect(error)}")
      end
    end

    defp handle_send_message_streaming(conn, agent_handler) do
      # TODO: Implement Server-Sent Events (SSE) streaming
      # For now, delegate to regular send_message
      handle_send_message(conn, agent_handler)
    end

    defp handle_poll_messages(conn, agent_handler) do
      query_params = conn.query_params
      agent_id = Map.get(query_params, "agent_id")

      if agent_id do
        case agent_handler.poll_messages(agent_id) do
          {:ok, messages} ->
            message_data =
              Enum.map(messages, fn message ->
                case A2A.JSON.encode(message) do
                  {:ok, encoded} -> encoded
                  {:error, _reason} -> nil
                end
              end)
              |> Enum.reject(&is_nil/1)

            send_json_response(conn, 200, %{messages: message_data})

          {:error, reason} ->
            send_error(conn, 400, "Failed to poll messages: #{inspect(reason)}")
        end
      else
        send_error(conn, 400, "Missing agent_id query parameter")
      end
    end

    defp handle_register_agent(conn, agent_handler) do
      with {:ok, body} <- read_json_body(conn),
           %{"agent_card" => agent_card_data} <- body,
           {:ok, agent_card} <- A2A.JSON.decode_agent_card(agent_card_data),
           {:ok, result} <- agent_handler.register_agent(agent_card) do
        send_json_response(conn, 200, %{result: result})
      else
        {:error, reason} ->
          send_error(conn, 400, "Bad request: #{inspect(reason)}")

        error ->
          send_error(conn, 500, "Internal error: #{inspect(error)}")
      end
    end

    defp handle_get_agent(conn, agent_handler, agent_id) do
      case agent_handler.get_agent(agent_id) do
        {:ok, agent_card} ->
          agent_card_json = A2A.JSON.encode_agent_card(agent_card, url: agent_card.url)
          send_json_response(conn, 200, %{agent_card: agent_card_json})

        {:error, :not_found} ->
          send_error(conn, 404, "Agent not found")

        {:error, reason} ->
          send_error(conn, 500, "Failed to get agent: #{inspect(reason)}")
      end
    end

    defp handle_get_card(conn, agent_handler) do
      case agent_handler.get_card() do
        {:ok, card_data} ->
          send_json_response(conn, 200, card_data)

        {:error, reason} ->
          send_error(conn, 500, "Failed to get card: #{inspect(reason)}")
      end
    end

    defp handle_get_task(conn, agent_handler, task_id) do
      case agent_handler.get_task(task_id) do
        {:ok, task} ->
          case A2A.JSON.encode(task) do
            {:ok, task_json} ->
              send_json_response(conn, 200, task_json)

            {:error, reason} ->
              send_error(conn, 500, "Failed to encode task: #{inspect(reason)}")
          end

        {:error, :not_found} ->
          send_error(conn, 404, "Task not found")

        {:error, reason} ->
          send_error(conn, 500, "Failed to get task: #{inspect(reason)}")
      end
    end

    defp handle_cancel_task(conn, agent_handler, task_id) do
      case agent_handler.cancel_task(task_id) do
        {:ok, result} ->
          send_json_response(conn, 200, %{result: result})

        {:error, :not_found} ->
          send_error(conn, 404, "Task not found")

        {:error, reason} ->
          send_error(conn, 500, "Failed to cancel task: #{inspect(reason)}")
      end
    end

    # Helper functions

    defp read_json_body(conn) do
      case Plug.Conn.read_body(conn) do
        {:ok, body, _conn} ->
          Jason.decode(body)

        {:more, _partial_body, _conn} ->
          {:error, :body_too_large}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp send_json_response(conn, status, data) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(data))
      |> halt()
    end

    defp send_error(conn, status, message) do
      error_data = %{error: message}
      send_json_response(conn, status, error_data)
    end

    defp generate_message_id do
      # Generate a unique message ID
      :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    end
  end
end
