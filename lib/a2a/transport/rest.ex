defmodule A2A.Transport.REST do
  @moduledoc """
  REST transport implementation for A2A protocol.

  This module provides REST/HTTP-JSON transport for A2A agents, offering
  direct HTTP endpoints without JSON-RPC wrapping. It includes both client
  and server implementations.

  ## Client Usage

      client = A2A.Transport.REST.Client
      {:ok, task} = A2A.Transport.REST.Client.send_message(
        "http://localhost:8080", 
        message, 
        agent_card
      )

  ## Server Usage

      # As a plug
      plug A2A.Transport.REST.Server, agent_handler: MyAgent

      # Or in Phoenix
      forward "/v1", A2A.Transport.REST.Server, agent_handler: MyAgent

  ## Protocol

  The REST transport implements the following endpoints:

  - `POST /v1/message/send` - Send a message
  - `POST /v1/message/stream` - Send a message with streaming response  
  - `GET /v1/messages` - Poll for messages
  - `POST /v1/agents` - Register an agent
  - `GET /v1/agents/:id` - Get agent information
  - `GET /v1/card` - Get agent card
  - `GET /v1/tasks/:id` - Get task information
  - `POST /v1/tasks/:id/cancel` - Cancel a task

  All endpoints use JSON payloads that match the A2A specification but
  without JSON-RPC wrapping.
  """

  @doc """
  Returns true if REST transport dependencies are available.
  """
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(Req) and Code.ensure_loaded?(Plug)
  end

  @doc """
  Creates a new REST client for the given endpoint.

  Delegates to `A2A.Transport.REST.Client`.
  """
  @spec new_client(String.t(), keyword()) :: term()
  def new_client(endpoint, opts \\ []) do
    if Code.ensure_loaded?(A2A.Transport.REST.Client) do
      %{endpoint: endpoint, opts: opts}
    else
      {:error, :rest_not_available}
    end
  end

  @doc """
  Creates a new REST server plug configuration.

  Delegates to `A2A.Transport.REST.Server`.
  """
  @spec new_server(keyword()) :: {module(), keyword()}
  def new_server(opts \\ []) do
    if Code.ensure_loaded?(A2A.Transport.REST.Server) do
      {A2A.Transport.REST.Server, opts}
    else
      {:error, :rest_not_available}
    end
  end
end
