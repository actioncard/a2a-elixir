defmodule A2A.Transport.REST.ClientTest do
  use ExUnit.Case, async: true

  if Code.ensure_loaded?(Req) do
    describe "public interface" do
      # Ensure the module is loaded before introspecting exported functions —
      # function_exported?/3 does not trigger code loading.
      setup do
        Code.ensure_loaded(A2A.Transport.REST.Client)
        :ok
      end

      test "send_message is exported" do
        assert function_exported?(A2A.Transport.REST.Client, :send_message, 3)
        assert function_exported?(A2A.Transport.REST.Client, :send_message, 4)
      end

      test "poll_messages is exported" do
        assert function_exported?(A2A.Transport.REST.Client, :poll_messages, 2)
        assert function_exported?(A2A.Transport.REST.Client, :poll_messages, 3)
      end

      test "register_agent is exported" do
        assert function_exported?(A2A.Transport.REST.Client, :register_agent, 2)
        assert function_exported?(A2A.Transport.REST.Client, :register_agent, 3)
      end

      test "get_agent is exported" do
        assert function_exported?(A2A.Transport.REST.Client, :get_agent, 2)
        assert function_exported?(A2A.Transport.REST.Client, :get_agent, 3)
      end

      test "get_card is exported" do
        assert function_exported?(A2A.Transport.REST.Client, :get_card, 1)
        assert function_exported?(A2A.Transport.REST.Client, :get_card, 2)
      end

      test "get_task is exported" do
        assert function_exported?(A2A.Transport.REST.Client, :get_task, 2)
        assert function_exported?(A2A.Transport.REST.Client, :get_task, 3)
      end

      test "cancel_task is exported" do
        assert function_exported?(A2A.Transport.REST.Client, :cancel_task, 2)
        assert function_exported?(A2A.Transport.REST.Client, :cancel_task, 3)
      end
    end
  end
end
