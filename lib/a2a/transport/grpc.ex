defmodule A2A.Transport.GRPC do
  @moduledoc """
  gRPC transport implementation for A2A protocol.

  This module provides gRPC transport for A2A agents using Protocol Buffers
  over HTTP/2. It includes both client and server implementations.

  ## Requirements

  The gRPC transport requires the optional `grpcbox` dependency:

      {:grpcbox, "~> 0.16"}

  ## Client Usage

      client = A2A.Transport.GRPC.new_client("127.0.0.1:50051")
      {:ok, task} = A2A.Transport.GRPC.Client.send_message(client, message)

  ## Server Usage

      {:ok, _pid} = A2A.Transport.GRPC.Server.start_link(
        agent: MyAgent,
        port: 50051
      )

  ## Protocol

  The gRPC transport implements the A2AService defined in `priv/proto/a2a.proto`:

  - `SendMessage` - Send a message and receive a task
  - `GetTask` - Get task status
  - `CancelTask` - Cancel a task
  - `ListTasks` - List tasks with pagination
  - `StreamMessage` - Send a message with server-side streaming
  - `GetAgentCard` - Get agent card

  ## Wire Format

  Follows A2A v1.0 wire format conventions:

  - Role enums: `ROLE_USER`, `ROLE_ASSISTANT` (maps to `:agent`), `ROLE_TOOL`
  - State enums: `TASK_STATE_SUBMITTED`, `TASK_STATE_ACTIVE` (maps to `:working`),
    `TASK_STATE_COMPLETED`, `TASK_STATE_FAILED`, `TASK_STATE_CANCELLED`

  All enum mappings are handled automatically by the transport layer.
  """

  @doc """
  Returns true if gRPC transport dependencies are available.
  """
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(:grpcbox)
  end

  @doc """
  Creates a new gRPC client for the given endpoint.

  ## Options

  - `:metadata` — Additional metadata to include in requests (default: `%{}`)
  - `:timeout` — Request timeout in milliseconds (default: 30_000)

  ## Examples

      client = A2A.Transport.GRPC.new_client("127.0.0.1:50051")
      client = A2A.Transport.GRPC.new_client("grpc.example.com:443", timeout: 60_000)
  """
  @spec new_client(String.t(), keyword()) :: term()
  def new_client(endpoint, opts \\ []) do
    if Code.ensure_loaded?(A2A.GRPC.Client) do
      A2A.GRPC.Client.new(endpoint, opts)
    else
      {:error, :grpcbox_not_available}
    end
  end

  @doc """
  Starts a gRPC server for the given agent.

  ## Options

  - `:agent` — GenServer name or pid of the agent (required)
  - `:port` — gRPC server port (default: 50051)
  - `:name` — GenServer name for the server process (optional)

  ## Examples

      {:ok, pid} = A2A.Transport.GRPC.start_server(agent: MyAgent, port: 50051)
  """
  @spec start_server(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_server(opts) do
    if Code.ensure_loaded?(A2A.GRPC.Server) do
      A2A.GRPC.Server.start_link(opts)
    else
      {:error, :grpcbox_not_available}
    end
  end

  @doc """
  Stops a gRPC server.
  """
  @spec stop_server(pid() | atom()) :: :ok
  def stop_server(server) do
    if Code.ensure_loaded?(A2A.GRPC.Server) do
      A2A.GRPC.Server.stop(server)
    else
      {:error, :grpcbox_not_available}
    end
  end

  @doc """
  Returns the configuration of a running gRPC server.
  """
  @spec get_server_config(pid() | atom()) :: map() | {:error, term()}
  def get_server_config(server) do
    if Code.ensure_loaded?(A2A.GRPC.Server) do
      A2A.GRPC.Server.get_config(server)
    else
      {:error, :grpcbox_not_available}
    end
  end
end
