defmodule A2A.ClientTest do
  use ExUnit.Case, async: true

  alias A2A.{Client, AgentCard}
  alias A2A.JSONRPC.Error

  @agent_card_json %{
    "name" => "test-agent",
    "description" => "A test agent",
    "url" => "https://agent.example.com",
    "version" => "1.0.0",
    "skills" => [
      %{
        "id" => "greet",
        "name" => "Greet",
        "description" => "Says hello",
        "tags" => ["greeting"]
      }
    ],
    "capabilities" => %{"streaming" => true},
    "defaultInputModes" => ["text/plain"],
    "defaultOutputModes" => ["text/plain"]
  }

  @task_json %{
    "kind" => "task",
    "id" => "tsk-123",
    "status" => %{"state" => "completed"},
    "history" => [
      %{
        "messageId" => "m-1",
        "role" => "user",
        "parts" => [%{"kind" => "text", "text" => "Hello"}]
      },
      %{
        "messageId" => "m-2",
        "role" => "agent",
        "parts" => [%{"kind" => "text", "text" => "Hi there!"}]
      }
    ],
    "artifacts" => [
      %{"parts" => [%{"kind" => "text", "text" => "Hi there!"}]}
    ]
  }

  defp jsonrpc_success(result, id \\ 1) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp jsonrpc_error(code, message, id \\ 1) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    }
  end

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  # -------------------------------------------------------------------
  # Discovery
  # -------------------------------------------------------------------

  describe "discover/2" do
    test "fetches and decodes agent card" do
      plug = fn conn ->
        json_resp(conn, 200, @agent_card_json)
      end

      assert {:ok, %AgentCard{} = card} =
               Client.discover("https://agent.example.com", plug: plug)

      assert card.name == "test-agent"
      assert card.description == "A test agent"
      assert card.url == "https://agent.example.com"
      assert card.version == "1.0.0"
      assert [%{id: "greet", name: "Greet"}] = card.skills
      assert card.capabilities == %{streaming: true}
    end

    test "returns error for non-200 status" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(404, "Not Found")
      end

      assert {:error, {:unexpected_status, 404}} =
               Client.discover("https://agent.example.com", plug: plug)
    end
  end

  # -------------------------------------------------------------------
  # send_message
  # -------------------------------------------------------------------

  describe "send_message/3" do
    test "sends message and returns decoded task" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["method"] == "message/send"
        assert decoded["params"]["message"]["role"] == "ROLE_USER"

        json_resp(conn, 200, jsonrpc_success(%{"task" => @task_json}))
      end

      client = Client.new("https://agent.example.com", plug: plug)
      assert {:ok, %A2A.Task{} = task} = Client.send_message(client, "Hello!")

      assert task.id == "tsk-123"
      assert task.status.state == :completed
      assert length(task.history) == 2
    end

    test "sends message with task_id and context_id" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["params"]["id"] == "tsk-existing"
        assert decoded["params"]["contextId"] == "ctx-42"

        json_resp(conn, 200, jsonrpc_success(%{"task" => @task_json}))
      end

      client = Client.new("https://agent.example.com", plug: plug)

      assert {:ok, _task} =
               Client.send_message(client, "More info",
                 task_id: "tsk-existing",
                 context_id: "ctx-42"
               )
    end

    test "returns JSON-RPC error" do
      plug = fn conn ->
        json_resp(conn, 200, jsonrpc_error(-32_001, "Task not found"))
      end

      client = Client.new("https://agent.example.com", plug: plug)

      assert {:error, %Error{code: -32_001, message: "Task not found"}} =
               Client.send_message(client, "Hello!")
    end

    test "accepts Message struct" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["params"]["message"]["role"] == "ROLE_USER"
        assert decoded["params"]["message"]["messageId"] == "msg-custom"

        json_resp(conn, 200, jsonrpc_success(%{"task" => @task_json}))
      end

      msg = %A2A.Message{
        message_id: "msg-custom",
        role: :user,
        parts: [A2A.Part.Text.new("Hello!")]
      }

      client = Client.new("https://agent.example.com", plug: plug)
      assert {:ok, _task} = Client.send_message(client, msg)
    end

    test "sends configuration options" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        config = decoded["params"]["configuration"]
        assert config["blocking"] == true
        assert config["historyLength"] == 5

        json_resp(conn, 200, jsonrpc_success(%{"task" => @task_json}))
      end

      client = Client.new("https://agent.example.com", plug: plug)

      assert {:ok, _task} =
               Client.send_message(client, "Hello!",
                 configuration: %{blocking: true, history_length: 5}
               )
    end

    test "sends metadata" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["params"]["metadata"] == %{"source" => "test"}

        json_resp(conn, 200, jsonrpc_success(%{"task" => @task_json}))
      end

      client = Client.new("https://agent.example.com", plug: plug)

      assert {:ok, _task} =
               Client.send_message(client, "Hello!", metadata: %{"source" => "test"})
    end
  end

  # -------------------------------------------------------------------
  # get_task
  # -------------------------------------------------------------------

  describe "get_task/3" do
    test "retrieves a task by ID" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["method"] == "tasks/get"
        assert decoded["params"]["id"] == "tsk-123"

        json_resp(conn, 200, jsonrpc_success(@task_json))
      end

      client = Client.new("https://agent.example.com", plug: plug)
      assert {:ok, %A2A.Task{id: "tsk-123"}} = Client.get_task(client, "tsk-123")
    end

    test "returns error for not found" do
      plug = fn conn ->
        json_resp(conn, 200, jsonrpc_error(-32_001, "Task not found"))
      end

      client = Client.new("https://agent.example.com", plug: plug)

      assert {:error, %Error{code: -32_001}} =
               Client.get_task(client, "tsk-missing")
    end
  end

  # -------------------------------------------------------------------
  # cancel_task
  # -------------------------------------------------------------------

  describe "cancel_task/3" do
    test "cancels a task by ID" do
      canceled_json = put_in(@task_json["status"]["state"], "canceled")

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["method"] == "tasks/cancel"
        assert decoded["params"]["id"] == "tsk-123"

        json_resp(conn, 200, jsonrpc_success(canceled_json))
      end

      client = Client.new("https://agent.example.com", plug: plug)
      assert {:ok, %A2A.Task{} = task} = Client.cancel_task(client, "tsk-123")
      assert task.status.state == :canceled
    end
  end

  # -------------------------------------------------------------------
  # stream_message
  # -------------------------------------------------------------------

  describe "stream_message/3" do
    @tag timeout: 10_000
    test "streams and decodes SSE events via Bandit" do
      status_event = %{
        "kind" => "status-update",
        "taskId" => "tsk-123",
        "status" => %{"state" => "working"},
        "final" => false
      }

      artifact_event = %{
        "kind" => "artifact-update",
        "taskId" => "tsk-123",
        "artifact" => %{
          "parts" => [%{"kind" => "text", "text" => "chunk"}]
        }
      }

      final_event = %{
        "kind" => "status-update",
        "taskId" => "tsk-123",
        "status" => %{"state" => "completed"},
        "final" => true
      }

      events = [status_event, artifact_event, final_event]

      sse_plug = {__MODULE__.SSEPlug, events: events}
      {:ok, server} = Bandit.start_link(plug: sse_plug, port: 0, ip: :loopback)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

      client = Client.new("http://127.0.0.1:#{port}")
      assert {:ok, stream} = Client.stream_message(client, "Count to 5")

      decoded = Enum.to_list(stream)
      assert length(decoded) == 3

      assert %A2A.Event.StatusUpdate{
               status: %{state: :working},
               final: false
             } = Enum.at(decoded, 0)

      assert %A2A.Event.ArtifactUpdate{artifact: %A2A.Artifact{}} =
               Enum.at(decoded, 1)

      assert %A2A.Event.StatusUpdate{
               status: %{state: :completed},
               final: true
             } = Enum.at(decoded, 2)

      GenServer.stop(server)
    end
  end

  defmodule SSEPlug do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts) do
      events = Keyword.fetch!(opts, :events)

      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.put_resp_header("cache-control", "no-cache")
        |> Plug.Conn.send_chunked(200)

      for event <- events, reduce: conn do
        conn ->
          payload = %{"jsonrpc" => "2.0", "id" => 1, "result" => event}
          data = "data: #{Jason.encode!(payload)}\n\n"
          {:ok, conn} = Plug.Conn.chunk(conn, data)
          conn
      end
    end
  end

  # -------------------------------------------------------------------
  # Method style
  # -------------------------------------------------------------------

  describe "method_style" do
    test "default (:legacy) sends slash-style method names" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["method"] == "message/send"
        json_resp(conn, 200, jsonrpc_success(%{"task" => @task_json}))
      end

      client = Client.new("https://agent.example.com", plug: plug)
      assert {:ok, _task} = Client.send_message(client, "Hello!")
    end

    test "v1 mode sends PascalCase method names" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["method"] == "SendMessage"
        json_resp(conn, 200, jsonrpc_success(%{"task" => @task_json}))
      end

      client = Client.new("https://agent.example.com", plug: plug, method_style: :v1)
      assert {:ok, _task} = Client.send_message(client, "Hello!")
    end

    test "legacy mode sends slash-style method names" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["method"] == "message/send"
        json_resp(conn, 200, jsonrpc_success(%{"task" => @task_json}))
      end

      client = Client.new("https://agent.example.com", plug: plug, method_style: :legacy)
      assert {:ok, _task} = Client.send_message(client, "Hello!")
    end

    test "legacy get_task sends tasks/get" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["method"] == "tasks/get"
        json_resp(conn, 200, jsonrpc_success(@task_json))
      end

      client = Client.new("https://agent.example.com", plug: plug, method_style: :legacy)
      assert {:ok, _task} = Client.get_task(client, "tsk-123")
    end

    test "legacy cancel_task sends tasks/cancel" do
      canceled_json = put_in(@task_json["status"]["state"], "canceled")

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["method"] == "tasks/cancel"
        json_resp(conn, 200, jsonrpc_success(canceled_json))
      end

      client = Client.new("https://agent.example.com", plug: plug, method_style: :legacy)
      assert {:ok, _task} = Client.cancel_task(client, "tsk-123")
    end
  end

  # -------------------------------------------------------------------
  # Convenience overloads
  # -------------------------------------------------------------------

  describe "convenience overloads" do
    test "accepts URL string directly" do
      plug = fn conn ->
        json_resp(conn, 200, jsonrpc_success(%{"task" => @task_json}))
      end

      client = Client.new("https://agent.example.com", plug: plug)

      assert {:ok, %A2A.Task{}} = Client.send_message(client, "Hello!")
    end

    test "accepts AgentCard directly" do
      plug = fn conn ->
        json_resp(conn, 200, jsonrpc_success(%{"task" => @task_json}))
      end

      card = %AgentCard{
        name: "test",
        description: "desc",
        url: "https://agent.example.com",
        version: "1.0.0",
        skills: []
      }

      client = Client.new(card, plug: plug)
      assert {:ok, %A2A.Task{}} = Client.send_message(client, "Hello!")
    end
  end
end
