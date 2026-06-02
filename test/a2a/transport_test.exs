defmodule A2A.TransportTest do
  use ExUnit.Case, async: true

  doctest A2A.Transport

  describe "available_transports/0" do
    test "always includes jsonrpc" do
      transports = A2A.Transport.available_transports()
      assert :jsonrpc in transports
    end

    test "includes rest when Req and Plug are available" do
      transports = A2A.Transport.available_transports()

      if Code.ensure_loaded?(Req) and Code.ensure_loaded?(Plug) do
        assert :rest in transports
      else
        refute :rest in transports
      end
    end

    test "includes grpc when grpcbox is available" do
      transports = A2A.Transport.available_transports()

      if Code.ensure_loaded?(:grpcbox) do
        assert :grpc in transports
      else
        refute :grpc in transports
      end
    end
  end

  describe "available?/1" do
    test "jsonrpc is always available" do
      assert A2A.Transport.available?(:jsonrpc)
    end

    test "rest availability depends on dependencies" do
      expected = Code.ensure_loaded?(Req) and Code.ensure_loaded?(Plug)
      assert A2A.Transport.available?(:rest) == expected
    end

    test "grpc availability depends on dependencies" do
      expected = Code.ensure_loaded?(:grpcbox)
      assert A2A.Transport.available?(:grpc) == expected
    end

    test "unknown transports are not available" do
      refute A2A.Transport.available?(:unknown)
      refute A2A.Transport.available?(:websocket)
    end
  end
end
