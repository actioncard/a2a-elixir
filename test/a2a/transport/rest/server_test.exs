defmodule A2A.Transport.REST.ServerTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  if Code.ensure_loaded?(Plug) do
    alias A2A.Transport.REST.Server
    alias A2A.AgentCard

    defmodule TestHandler do
      @behaviour A2A.Agent

      def agent_card do
        %AgentCard{
          name: "test-agent",
          description: "Test agent for REST transport",
          url: "http://localhost:8080",
          version: "1.0.0",
          skills: []
        }
      end

      def handle_message(message, _agent_card) do
        {:ok, "Message received: #{A2A.Message.text(message)}"}
      end

      def handle_cancel(_context), do: :ok

      def poll_messages(_agent_id) do
        {:ok, []}
      end

      def register_agent(_agent_card) do
        {:ok, :registered}
      end

      def get_agent(_agent_id) do
        {:error, :not_found}
      end

      def get_card do
        {:ok,
         %{
           name: "test-agent",
           version: "1.0.0"
         }}
      end

      def get_task(_task_id) do
        {:error, :not_found}
      end

      def cancel_task(_task_id) do
        {:error, :not_found}
      end
    end

    @opts Server.init(agent_handler: TestHandler)

    test "GET /v1/card returns agent card" do
      conn =
        :get
        |> conn("/v1/card")
        |> Server.call(@opts)

      assert conn.status == 200

      assert conn.resp_body |> Jason.decode!() == %{
               "name" => "test-agent",
               "version" => "1.0.0"
             }
    end

    test "GET /v1/messages with agent_id returns messages" do
      conn =
        :get
        |> conn("/v1/messages?agent_id=test-agent")
        |> Server.call(@opts)

      assert conn.status == 200
      response = conn.resp_body |> Jason.decode!()
      assert response["messages"] == []
    end

    test "GET /v1/messages without agent_id returns error" do
      conn =
        :get
        |> conn("/v1/messages")
        |> Server.call(@opts)

      assert conn.status == 400
      response = conn.resp_body |> Jason.decode!()
      assert response["error"] == "Missing agent_id query parameter"
    end

    test "GET /v1/agents/:id returns 404 for unknown agent" do
      conn =
        :get
        |> conn("/v1/agents/unknown")
        |> Server.call(@opts)

      assert conn.status == 404
      response = conn.resp_body |> Jason.decode!()
      assert response["error"] == "Agent not found"
    end

    test "POST /v1/agents registers agent" do
      agent_card_json = %{
        "name" => "new-agent",
        "description" => "New test agent",
        "url" => "http://localhost:8080",
        "version" => "1.0.0",
        "skills" => []
      }

      conn =
        :post
        |> conn("/v1/agents", Jason.encode!(%{agent_card: agent_card_json}))
        |> put_req_header("content-type", "application/json")
        |> Server.call(@opts)

      assert conn.status == 200
      response = conn.resp_body |> Jason.decode!()
      assert response["result"] == "registered"
    end

    test "POST /v1/message/send processes message" do
      message_json = %{
        "messageId" => "msg-123",
        "role" => "user",
        "parts" => [%{"kind" => "text", "text" => "Hello"}]
      }

      agent_card_json = %{
        "name" => "test-agent",
        "description" => "Test agent",
        "url" => "http://localhost:8080",
        "version" => "1.0.0",
        "skills" => []
      }

      conn =
        :post
        |> conn(
          "/v1/message/send",
          Jason.encode!(%{
            message: message_json,
            agent_card: agent_card_json
          })
        )
        |> put_req_header("content-type", "application/json")
        |> Server.call(@opts)

      assert conn.status == 200
      response = conn.resp_body |> Jason.decode!()
      assert Map.has_key?(response, "message_id")
      assert response["result"] == "Message received: Hello"
    end

    test "GET /v1/tasks/:id returns 404 for unknown task" do
      conn =
        :get
        |> conn("/v1/tasks/unknown")
        |> Server.call(@opts)

      assert conn.status == 404
      response = conn.resp_body |> Jason.decode!()
      assert response["error"] == "Task not found"
    end

    test "POST /v1/tasks/:id/cancel returns 404 for unknown task" do
      conn =
        :post
        |> conn("/v1/tasks/unknown/cancel")
        |> put_req_header("content-type", "application/json")
        |> Server.call(@opts)

      assert conn.status == 404
      response = conn.resp_body |> Jason.decode!()
      assert response["error"] == "Task not found"
    end

    test "unknown endpoint returns 404" do
      conn =
        :get
        |> conn("/v1/unknown")
        |> Server.call(@opts)

      assert conn.status == 404
      response = conn.resp_body |> Jason.decode!()
      assert response["error"] == "Endpoint not found"
    end
  end
end
