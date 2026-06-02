defmodule A2A.Transport do
  @moduledoc """
  Multi-transport support for A2A protocol.

  This module provides a unified interface for different A2A transport
  protocols. Currently supports:

  - **JSON-RPC 2.0** (via HTTP) - Default transport in `A2A.Plug` and `A2A.Client`
  - **REST/HTTP-JSON** - Direct HTTP endpoints via `A2A.Transport.REST`
  - **gRPC** - Protocol Buffers over HTTP/2 via `A2A.Transport.GRPC`

  ## Usage

  ### Check Available Transports

      A2A.Transport.available_transports()
      #=> [:jsonrpc, :rest, :grpc]

  ### REST Transport

      # Client
      client = A2A.Transport.REST.new_client("http://localhost:8080")
      {:ok, task} = A2A.Transport.REST.Client.send_message(client, message, agent_card)

      # Server
      plug A2A.Transport.REST.Server, agent_handler: MyAgent

  ### gRPC Transport

      # Client  
      client = A2A.Transport.GRPC.new_client("127.0.0.1:50051")
      {:ok, task} = A2A.Transport.GRPC.Client.send_message(client, message)

      # Server
      {:ok, _pid} = A2A.Transport.GRPC.Server.start_link(agent: MyAgent, port: 50051)

  ## Design

  Each transport implements the same A2A protocol operations but uses different
  wire formats and communication patterns:

  - **JSON-RPC**: Single HTTP endpoint with method dispatch
  - **REST**: Multiple HTTP endpoints with resource-based routing
  - **gRPC**: Strongly-typed service definitions over HTTP/2

  All transports share the same internal A2A data structures and agent behavior.
  """

  @doc """
  Returns a list of available transport protocols.

  Checks for optional dependencies and returns only transports that can be used.
  """
  @spec available_transports() :: [atom()]
  def available_transports do
    transports = []

    # Always available
    transports = [:jsonrpc | transports]

    transports =
      if A2A.Transport.REST.available?() do
        [:rest | transports]
      else
        transports
      end

    transports =
      if A2A.Transport.GRPC.available?() do
        [:grpc | transports]
      else
        transports
      end

    Enum.reverse(transports)
  end

  @doc """
  Checks if a specific transport is available.
  """
  @spec available?(atom()) :: boolean()
  def available?(:jsonrpc), do: true
  def available?(:rest), do: A2A.Transport.REST.available?()
  def available?(:grpc), do: A2A.Transport.GRPC.available?()
  def available?(_), do: false
end
