if Code.ensure_loaded?(:grpcbox) do
  defmodule A2A.GRPC.Client do
    @moduledoc """
    gRPC client implementation for A2A agents.

    Provides a gRPC client that can communicate with A2A agents over gRPC transport.
    Implements the same interface as A2A.Client but uses gRPC instead of HTTP.

    ## Usage

        client = A2A.GRPC.Client.new("127.0.0.1:50051")
        {:ok, task} = A2A.GRPC.Client.send_message(client, message)

    ## Configuration

    The client accepts the same options as the HTTP client but connects via gRPC.
    """

    require Logger

    defstruct [:endpoint, :channel, :metadata, :timeout]

    @type t :: %__MODULE__{
            endpoint: binary(),
            channel: term(),
            metadata: map(),
            timeout: pos_integer()
          }

    @doc """
    Creates a new gRPC client for the given endpoint.

    ## Options

    - `:metadata` — Additional metadata to include in requests (default: `%{}`)
    - `:timeout` — Request timeout in milliseconds (default: 30_000)

    ## Examples

        client = A2A.GRPC.Client.new("127.0.0.1:50051")
        client = A2A.GRPC.Client.new("grpc.example.com:443", timeout: 60_000)
    """
    @spec new(binary(), keyword()) :: t()
    def new(endpoint, opts \\ []) do
      %__MODULE__{
        endpoint: endpoint,
        channel: nil,
        metadata: Keyword.get(opts, :metadata, %{}),
        timeout: Keyword.get(opts, :timeout, 30_000)
      }
    end

    @doc """
    Establishes a connection to the gRPC server.

    This is optional - connections will be established automatically when needed.
    """
    @spec connect(t()) :: {:ok, t()} | {:error, term()}
    def connect(client) do
      # In a real implementation, this would establish a gRPC channel
      # For now, just return the client with a mock channel
      Logger.debug("Connecting to gRPC endpoint: #{client.endpoint}")
      {:ok, %{client | channel: :mock_channel}}
    end

    @doc """
    Closes the connection to the gRPC server.
    """
    @spec disconnect(t()) :: :ok
    def disconnect(client) do
      Logger.debug("Disconnecting from gRPC endpoint: #{client.endpoint}")
      :ok
    end

    @doc """
    Sends a message to the agent via gRPC.

    ## Parameters

    - `client` — The gRPC client
    - `message` — The A2A.Message to send
    - `opts` — Additional options

    ## Options

    - `:timeout` — Request timeout (overrides client default)
    - `:metadata` — Additional request metadata

    ## Returns

    - `{:ok, task}` — Success with the resulting A2A.Task
    - `{:error, reason}` — Failure with error details
    """
    @spec send_message(t(), A2A.Message.t(), keyword()) ::
            {:ok, A2A.Task.t()} | {:error, term()}
    def send_message(client, message, opts \\ []) do
      Logger.debug("Sending gRPC message to #{client.endpoint}")

      # In a real implementation, this would:
      # 1. Encode the message to gRPC format
      # 2. Call the SendMessage RPC
      # 3. Decode the response to A2A.Task

      # For now, return an error indicating not implemented
      _ = {client, message, opts}
      {:error, :grpc_not_implemented}
    end

    @doc """
    Retrieves a task by ID via gRPC.
    """
    @spec get_task(t(), binary(), keyword()) :: {:ok, A2A.Task.t()} | {:error, term()}
    def get_task(client, task_id, opts \\ []) do
      Logger.debug("Getting gRPC task #{task_id} from #{client.endpoint}")
      _ = {client, task_id, opts}
      {:error, :grpc_not_implemented}
    end

    @doc """
    Cancels a task by ID via gRPC.
    """
    @spec cancel_task(t(), binary(), keyword()) :: {:ok, A2A.Task.t()} | {:error, term()}
    def cancel_task(client, task_id, opts \\ []) do
      Logger.debug("Cancelling gRPC task #{task_id} on #{client.endpoint}")
      _ = {client, task_id, opts}
      {:error, :grpc_not_implemented}
    end

    @doc """
    Lists tasks via gRPC.
    """
    @spec list_tasks(t(), keyword()) :: {:ok, [A2A.Task.t()]} | {:error, term()}
    def list_tasks(client, opts \\ []) do
      Logger.debug("Listing gRPC tasks from #{client.endpoint}")
      _ = {client, opts}
      {:error, :grpc_not_implemented}
    end

    @doc """
    Streams a message to the agent via gRPC.

    Returns a stream of task updates.
    """
    @spec stream_message(t(), A2A.Message.t(), keyword()) ::
            {:ok, Enumerable.t()} | {:error, term()}
    def stream_message(client, message, opts \\ []) do
      Logger.debug("Streaming gRPC message to #{client.endpoint}")
      _ = {client, message, opts}
      {:error, :grpc_not_implemented}
    end

    @doc """
    Gets the agent card via gRPC.
    """
    @spec get_agent_card(t(), keyword()) :: {:ok, map()} | {:error, term()}
    def get_agent_card(client, opts \\ []) do
      Logger.debug("Getting gRPC agent card from #{client.endpoint}")
      _ = {client, opts}
      {:error, :grpc_not_implemented}
    end
  end
else
  defmodule A2A.GRPC.Client do
    @moduledoc """
    gRPC client implementation (requires grpcbox dependency).

    This module is only available when grpcbox is loaded.
    """

    def new(_endpoint, _opts \\ []) do
      {:error, :grpcbox_not_available}
    end

    def connect(_client) do
      {:error, :grpcbox_not_available}
    end

    def disconnect(_client) do
      {:error, :grpcbox_not_available}
    end

    def send_message(_client, _message, _opts \\ []) do
      {:error, :grpcbox_not_available}
    end

    def get_task(_client, _task_id, _opts \\ []) do
      {:error, :grpcbox_not_available}
    end

    def cancel_task(_client, _task_id, _opts \\ []) do
      {:error, :grpcbox_not_available}
    end

    def list_tasks(_client, _opts \\ []) do
      {:error, :grpcbox_not_available}
    end

    def stream_message(_client, _message, _opts \\ []) do
      {:error, :grpcbox_not_available}
    end

    def get_agent_card(_client, _opts \\ []) do
      {:error, :grpcbox_not_available}
    end
  end
end
