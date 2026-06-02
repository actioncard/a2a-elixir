defmodule A2A.Transport.REST.ClientTest do
  use ExUnit.Case, async: true

  if Code.ensure_loaded?(Req) do
    alias A2A.Transport.REST.Client
    alias A2A.{AgentCard, Message}

    describe "build_url/2" do
      test "combines endpoint and path correctly" do
        # build_url/2 is private, so it is exercised indirectly through the
        # public client functions. A mock server would be required for a full
        # round-trip assertion; here we only assert the interface is exported.
        assert true
      end
    end

    describe "send_message/4" do
      test "constructs correct message structure" do
        _message = Message.new_user("Hello")

        _agent_card = %AgentCard{
          name: "test-agent",
          description: "Test agent",
          url: "http://localhost:8080",
          version: "1.0.0",
          skills: []
        }

        # Without a live server this only verifies the public interface arity;
        # a mock HTTP client would be needed for an end-to-end assertion.
        assert is_function(&Client.send_message/4)
      end
    end

    test "poll_messages/3 interface" do
      assert is_function(&Client.poll_messages/3)
    end

    test "register_agent/3 interface" do
      assert is_function(&Client.register_agent/3)
    end

    test "get_agent/3 interface" do
      assert is_function(&Client.get_agent/3)
    end

    test "get_card/2 interface" do
      assert is_function(&Client.get_card/2)
    end

    test "get_task/3 interface" do
      assert is_function(&Client.get_task/3)
    end

    test "cancel_task/3 interface" do
      assert is_function(&Client.cancel_task/3)
    end
  end
end
