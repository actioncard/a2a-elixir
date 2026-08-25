if Code.ensure_loaded?(Req) do
  defmodule A2A.Transport.REST.Client do
    @moduledoc """
    REST/HTTP-JSON transport client for A2A protocol.

    Provides direct HTTP calls to REST endpoints (no JSON-RPC wrapper).
    Compatible with Python/Go REST transport implementations.
    """

    alias A2A.{AgentCard, Message, Task}

    @doc """
    Send a message via REST transport.
    """
    @spec send_message(String.t(), Message.t(), AgentCard.t(), keyword()) ::
            {:ok, String.t()} | {:error, term()}
    def send_message(endpoint, message, agent_card, opts \\ []) do
      url = build_url(endpoint, "/v1/message:send")

      with {:ok, message_json} <- A2A.JSON.encode(message) do
        body = %{
          message: message_json,
          agent_card: A2A.JSON.encode_agent_card(agent_card, url: agent_card.url)
        }

        case post_json(url, body, opts) do
          {:ok, %{"message_id" => message_id}} -> {:ok, message_id}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    @doc """
    Poll for messages via REST transport.
    """
    @spec poll_messages(String.t(), AgentCard.t(), keyword()) ::
            {:ok, [Message.t()]} | {:error, term()}
    def poll_messages(endpoint, agent_card, opts \\ []) do
      url = build_url(endpoint, "/v1/messages")
      # AgentCard.name is the agent ID
      query = %{agent_id: agent_card.name}

      case get_json(url, query, opts) do
        {:ok, %{"messages" => messages}} ->
          parsed_messages =
            Enum.map(messages, fn msg_data ->
              case A2A.JSON.decode(msg_data, :message) do
                {:ok, message} -> message
                {:error, _reason} -> nil
              end
            end)
            |> Enum.reject(&is_nil/1)

          {:ok, parsed_messages}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @doc """
    Register an agent via REST transport.
    """
    @spec register_agent(String.t(), AgentCard.t(), keyword()) ::
            {:ok, :registered} | {:error, term()}
    def register_agent(endpoint, agent_card, opts \\ []) do
      url = build_url(endpoint, "/v1/agents")
      body = %{agent_card: A2A.JSON.encode_agent_card(agent_card, url: agent_card.url)}

      case post_json(url, body, opts) do
        {:ok, _response} -> {:ok, :registered}
        {:error, reason} -> {:error, reason}
      end
    end

    @doc """
    Get agent information via REST transport.
    """
    @spec get_agent(String.t(), String.t(), keyword()) ::
            {:ok, AgentCard.t()} | {:error, term()}
    def get_agent(endpoint, agent_id, opts \\ []) do
      url = build_url(endpoint, "/v1/agents/#{agent_id}")

      case get_json(url, %{}, opts) do
        {:ok, %{"agent_card" => card_data}} ->
          A2A.JSON.decode_agent_card(card_data)

        {:error, reason} ->
          {:error, reason}
      end
    end

    @doc """
    Get agent card (extended) via REST transport.
    """
    @spec get_card(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
    def get_card(endpoint, opts \\ []) do
      url = build_url(endpoint, "/v1/card")
      get_json(url, %{}, opts)
    end

    @doc """
    Get task information via REST transport.
    """
    @spec get_task(String.t(), String.t(), keyword()) ::
            {:ok, Task.t()} | {:error, term()}
    def get_task(endpoint, task_id, opts \\ []) do
      url = build_url(endpoint, "/v1/tasks/#{task_id}")

      case get_json(url, %{}, opts) do
        {:ok, task_data} ->
          A2A.JSON.decode(task_data, :task)

        {:error, reason} ->
          {:error, reason}
      end
    end

    @doc """
    Cancel a task via REST transport.
    """
    @spec cancel_task(String.t(), String.t(), keyword()) ::
            {:ok, :cancelled} | {:error, term()}
    def cancel_task(endpoint, task_id, opts \\ []) do
      url = build_url(endpoint, "/v1/tasks/#{task_id}:cancel")

      case post_json(url, %{}, opts) do
        {:ok, _response} -> {:ok, :cancelled}
        {:error, reason} -> {:error, reason}
      end
    end

    # Private helper functions

    defp build_url(endpoint, path) do
      endpoint = String.trim_trailing(endpoint, "/")
      "#{endpoint}#{path}"
    end

    defp post_json(url, body, opts) do
      timeout = Keyword.get(opts, :timeout, 30_000)

      req =
        Req.new(
          headers: [{"content-type", "application/json"}, {"accept", "application/json"}],
          receive_timeout: timeout
        )

      json_body = Jason.encode!(body)

      case Req.post(req, url: url, body: json_body) do
        {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
          {:ok, response_body}

        {:ok, %Req.Response{status: status, body: error_body}} ->
          {:error, %{status: status, body: error_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp get_json(url, query, opts) do
      timeout = Keyword.get(opts, :timeout, 30_000)

      req =
        Req.new(
          headers: [{"accept", "application/json"}],
          receive_timeout: timeout
        )

      case Req.get(req, url: url, params: query) do
        {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
          {:ok, response_body}

        {:ok, %Req.Response{status: status, body: error_body}} ->
          {:error, %{status: status, body: error_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
