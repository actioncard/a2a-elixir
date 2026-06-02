defmodule A2A.GRPCTest do
  use ExUnit.Case, async: true

  alias A2A.GRPC.{Server, Client}

  describe "A2A.GRPC module" do
    test "module exists and is loadable" do
      assert Code.ensure_loaded?(A2A.GRPC)
    end

    test "has required functions" do
      # Ensure the module is loaded before introspecting exported functions —
      # function_exported?/3 does not trigger code loading, and the module is
      # compiled conditionally, so an unrelated test may not have loaded it yet.
      Code.ensure_loaded(A2A.GRPC)
      assert function_exported?(A2A.GRPC, :start_server, 1)
      assert function_exported?(A2A.GRPC, :decode_grpc_request, 2)
      assert function_exported?(A2A.GRPC, :encode_grpc_response, 1)
    end
  end

  describe "A2A.GRPC.Server" do
    test "module exists and is loadable" do
      assert Code.ensure_loaded?(A2A.GRPC.Server)
    end

    test "has required functions" do
      Code.ensure_loaded(A2A.GRPC.Server)
      assert function_exported?(A2A.GRPC.Server, :start_link, 1)
      assert function_exported?(A2A.GRPC.Server, :stop, 1)
      assert function_exported?(A2A.GRPC.Server, :get_config, 1)
    end

    @tag :grpc
    test "starts server with valid configuration" do
      if Code.ensure_loaded?(:grpcbox) do
        # Create a mock agent
        {:ok, agent} = Agent.start_link(fn -> %{} end)

        # Start the gRPC server
        opts = [agent: agent, port: 50051]
        assert {:ok, server} = Server.start_link(opts)

        # Get config
        config = Server.get_config(server)
        assert config.agent == agent
        assert config.port == 50051
        assert config.running == true

        # Stop server
        assert :ok = Server.stop(server)

        # Clean up agent
        Agent.stop(agent)
      else
        # When grpcbox is not available, should return error
        assert {:error, :grpcbox_not_available} = Server.start_link(agent: self(), port: 50051)
      end
    end

    test "requires agent option" do
      if Code.ensure_loaded?(:grpcbox) do
        # This should fail because no agent is provided
        # Use Process.flag to capture exits
        Process.flag(:trap_exit, true)

        case Server.start_link(port: 50051) do
          {:error, {%KeyError{key: :agent}, _}} ->
            # Expected - the KeyError comes from init/1
            assert true

          {:ok, server} ->
            # Clean up if somehow succeeded
            Server.stop(server)
            flunk("Expected KeyError when agent option is missing")
        end

        Process.flag(:trap_exit, false)
      end
    end

    test "uses default port when not specified" do
      if Code.ensure_loaded?(:grpcbox) do
        {:ok, agent} = Agent.start_link(fn -> %{} end)

        {:ok, server} = Server.start_link(agent: agent)
        config = Server.get_config(server)

        assert config.port == 50051

        Server.stop(server)
        Agent.stop(agent)
      end
    end
  end

  describe "A2A.GRPC.Client" do
    test "module exists and is loadable" do
      assert Code.ensure_loaded?(A2A.GRPC.Client)
    end

    test "has required functions" do
      Code.ensure_loaded(A2A.GRPC.Client)

      assert function_exported?(A2A.GRPC.Client, :new, 1) or
               function_exported?(A2A.GRPC.Client, :new, 2)

      assert function_exported?(A2A.GRPC.Client, :connect, 1)
      assert function_exported?(A2A.GRPC.Client, :disconnect, 1)

      assert function_exported?(A2A.GRPC.Client, :send_message, 2) or
               function_exported?(A2A.GRPC.Client, :send_message, 3)

      assert function_exported?(A2A.GRPC.Client, :get_task, 2) or
               function_exported?(A2A.GRPC.Client, :get_task, 3)
    end

    @tag :grpc
    test "creates client with endpoint" do
      if Code.ensure_loaded?(:grpcbox) do
        client = Client.new("127.0.0.1:50051")
        assert client.endpoint == "127.0.0.1:50051"
        assert client.metadata == %{}
        assert client.timeout == 30_000
      else
        assert {:error, :grpcbox_not_available} = Client.new("127.0.0.1:50051")
      end
    end

    @tag :grpc
    test "creates client with custom options" do
      if Code.ensure_loaded?(:grpcbox) do
        client =
          Client.new("grpc.example.com:443", timeout: 60_000, metadata: %{"x-api-key" => "test"})

        assert client.endpoint == "grpc.example.com:443"
        assert client.metadata == %{"x-api-key" => "test"}
        assert client.timeout == 60_000
      end
    end

    @tag :grpc
    test "connect establishes connection" do
      if Code.ensure_loaded?(:grpcbox) do
        client = Client.new("127.0.0.1:50051")
        assert {:ok, connected_client} = Client.connect(client)
        assert connected_client.channel == :mock_channel
      end
    end

    @tag :grpc
    test "client methods return not_implemented for now" do
      if Code.ensure_loaded?(:grpcbox) do
        client = Client.new("127.0.0.1:50051")

        # Create a minimal message for testing
        message = %A2A.Message{
          role: :user,
          parts: [%A2A.Part.Text{text: "test"}]
        }

        # All methods should return :grpc_not_implemented for now
        assert {:error, :grpc_not_implemented} = Client.send_message(client, message)
        assert {:error, :grpc_not_implemented} = Client.get_task(client, "task-123")
        assert {:error, :grpc_not_implemented} = Client.cancel_task(client, "task-123")
        assert {:error, :grpc_not_implemented} = Client.list_tasks(client)
        assert {:error, :grpc_not_implemented} = Client.stream_message(client, message)
        assert {:error, :grpc_not_implemented} = Client.get_agent_card(client)
      end
    end
  end

  describe "gRPC transport availability" do
    test "grpcbox dependency status" do
      if Code.ensure_loaded?(:grpcbox) do
        assert true, "grpcbox is available"
      else
        # This is expected if grpcbox is not included
        assert true, "grpcbox is optional - not loaded"
      end
    end
  end
end
