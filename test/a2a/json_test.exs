defmodule A2A.JSONTest do
  use ExUnit.Case, async: true

  alias A2A.JSON
  alias A2A.{Task, Message, Artifact, FileContent, Part}
  alias A2A.Event.{StatusUpdate, ArtifactUpdate}

  # -------------------------------------------------------------------
  # Encoding
  # -------------------------------------------------------------------

  describe "encode Part.Text" do
    test "produces camelCase map" do
      part = Part.Text.new("hello")
      assert {:ok, %{"kind" => "text", "text" => "hello"}} = JSON.encode(part)
    end

    test "omits empty metadata" do
      {:ok, map} = JSON.encode(Part.Text.new("hi"))
      refute Map.has_key?(map, "metadata")
    end

    test "includes non-empty metadata" do
      {:ok, map} = JSON.encode(Part.Text.new("hi", %{lang: "en"}))
      assert map["metadata"] == %{lang: "en"}
    end
  end

  describe "encode Part.File" do
    test "encodes file with bytes as base64" do
      fc =
        FileContent.from_bytes("binary data",
          name: "f.bin",
          mime_type: "application/octet-stream"
        )

      part = Part.File.new(fc)
      {:ok, map} = JSON.encode(part)

      assert map["kind"] == "file"
      assert map["file"]["bytes"] == Base.encode64("binary data")
      assert map["file"]["name"] == "f.bin"
      assert map["file"]["mimeType"] == "application/octet-stream"
    end

    test "encodes file with URI" do
      fc = FileContent.from_uri("https://example.com/file.pdf")
      part = Part.File.new(fc)
      {:ok, map} = JSON.encode(part)

      assert map["file"]["uri"] == "https://example.com/file.pdf"
      refute Map.has_key?(map["file"], "bytes")
    end
  end

  describe "encode Part.Data" do
    test "produces camelCase map" do
      part = Part.Data.new(%{key: "val"})
      {:ok, map} = JSON.encode(part)

      assert map["kind"] == "data"
      assert map["data"] == %{key: "val"}
    end
  end

  describe "encode FileContent" do
    test "encodes bytes to base64" do
      fc = FileContent.from_bytes(<<0, 1, 2, 3>>, name: "test.bin")
      {:ok, map} = JSON.encode(fc)

      assert map["bytes"] == Base.encode64(<<0, 1, 2, 3>>)
      assert map["name"] == "test.bin"
    end

    test "omits nil fields" do
      fc = FileContent.from_uri("https://example.com/f")
      {:ok, map} = JSON.encode(fc)

      assert map["uri"] == "https://example.com/f"
      refute Map.has_key?(map, "bytes")
      refute Map.has_key?(map, "name")
      refute Map.has_key?(map, "mimeType")
    end
  end

  describe "encode Message" do
    test "produces camelCase map with kind" do
      msg = %Message{
        message_id: "msg-1",
        role: :user,
        parts: [Part.Text.new("hello")],
        task_id: "tsk-1",
        context_id: "ctx-1"
      }

      {:ok, map} = JSON.encode(msg)

      assert map["kind"] == "message"
      assert map["messageId"] == "msg-1"
      assert map["role"] == "user"
      assert map["taskId"] == "tsk-1"
      assert map["contextId"] == "ctx-1"
      assert [%{"kind" => "text", "text" => "hello"}] = map["parts"]
    end

    test "omits nil optional fields" do
      msg = %Message{role: :agent, parts: [Part.Text.new("hi")]}
      {:ok, map} = JSON.encode(msg)

      refute Map.has_key?(map, "messageId")
      refute Map.has_key?(map, "taskId")
      refute Map.has_key?(map, "contextId")
      refute Map.has_key?(map, "metadata")
      refute Map.has_key?(map, "extensions")
    end
  end

  describe "encode Artifact" do
    test "produces camelCase map" do
      artifact = %Artifact{
        artifact_id: "art-1",
        name: "result",
        description: "desc",
        parts: [Part.Text.new("output")],
        metadata: %{type: "text"}
      }

      {:ok, map} = JSON.encode(artifact)

      assert map["artifactId"] == "art-1"
      assert map["name"] == "result"
      assert map["description"] == "desc"
      assert [%{"kind" => "text"}] = map["parts"]
      assert map["metadata"] == %{type: "text"}
    end

    test "omits nil optional fields" do
      artifact = %Artifact{parts: [Part.Text.new("x")]}
      {:ok, map} = JSON.encode(artifact)

      refute Map.has_key?(map, "artifactId")
      refute Map.has_key?(map, "name")
      refute Map.has_key?(map, "description")
      refute Map.has_key?(map, "metadata")
    end
  end

  describe "encode Task.Status" do
    test "encodes state atoms to hyphenated strings" do
      status = Task.Status.new(:input_required)
      {:ok, map} = JSON.encode(status)
      assert map["state"] == "input-required"
    end

    test "encodes auth_required" do
      status = Task.Status.new(:auth_required)
      {:ok, map} = JSON.encode(status)
      assert map["state"] == "auth-required"
    end

    test "encodes simple state as string" do
      status = Task.Status.new(:working)
      {:ok, map} = JSON.encode(status)
      assert map["state"] == "working"
    end

    test "encodes timestamp as ISO8601" do
      status = Task.Status.new(:submitted)
      {:ok, map} = JSON.encode(status)
      assert {:ok, _, _} = DateTime.from_iso8601(map["timestamp"])
    end

    test "encodes nested message" do
      msg = Message.new_agent("status info")
      status = Task.Status.new(:working, msg)
      {:ok, map} = JSON.encode(status)
      assert map["message"]["kind"] == "message"
      assert map["message"]["role"] == "agent"
    end

    test "omits nil message" do
      status = Task.Status.new(:working)
      {:ok, map} = JSON.encode(status)
      refute Map.has_key?(map, "message")
    end
  end

  describe "encode Task" do
    test "produces full camelCase map with kind" do
      task = Task.new(context_id: "ctx-1")
      {:ok, map} = JSON.encode(task)

      assert map["kind"] == "task"
      assert is_binary(map["id"])
      assert map["contextId"] == "ctx-1"
      assert map["status"]["state"] == "submitted"
    end

    test "omits empty history and artifacts" do
      task = Task.new()
      {:ok, map} = JSON.encode(task)

      refute Map.has_key?(map, "history")
      refute Map.has_key?(map, "artifacts")
    end

    test "includes non-empty history" do
      msg = Message.new_user("hello")
      task = Task.new(history: [msg])
      {:ok, map} = JSON.encode(task)

      assert [%{"kind" => "message"}] = map["history"]
    end
  end

  describe "encode StatusUpdate event" do
    test "produces camelCase map" do
      status = Task.Status.new(:working)
      event = StatusUpdate.new("tsk-1", status, context_id: "ctx-1", final: false)
      {:ok, map} = JSON.encode(event)

      assert map["kind"] == "status-update"
      assert map["taskId"] == "tsk-1"
      assert map["contextId"] == "ctx-1"
      assert map["final"] == false
      assert map["status"]["state"] == "working"
    end
  end

  describe "encode ArtifactUpdate event" do
    test "produces camelCase map" do
      artifact = Artifact.new([Part.Text.new("chunk")])

      event =
        ArtifactUpdate.new("tsk-1", artifact,
          context_id: "ctx-1",
          append: true,
          last_chunk: false
        )

      {:ok, map} = JSON.encode(event)

      assert map["kind"] == "artifact-update"
      assert map["taskId"] == "tsk-1"
      assert map["contextId"] == "ctx-1"
      assert map["append"] == true
      assert map["lastChunk"] == false
    end

    test "omits nil append and lastChunk" do
      artifact = Artifact.new([Part.Text.new("x")])
      event = ArtifactUpdate.new("tsk-1", artifact)
      {:ok, map} = JSON.encode(event)

      refute Map.has_key?(map, "append")
      refute Map.has_key?(map, "lastChunk")
    end
  end

  describe "encode unsupported type" do
    test "returns error for unknown struct" do
      assert {:error, {:unsupported_type, URI}} = JSON.encode(URI.parse("http://example.com"))
    end
  end

  # -------------------------------------------------------------------
  # Decoding
  # -------------------------------------------------------------------

  describe "decode :part" do
    test "decodes text part" do
      {:ok, part} = JSON.decode(%{"kind" => "text", "text" => "hello"}, :part)
      assert %Part.Text{kind: :text, text: "hello", metadata: %{}} = part
    end

    test "decodes file part with base64 bytes" do
      encoded = Base.encode64("raw bytes")

      {:ok, part} =
        JSON.decode(
          %{
            "kind" => "file",
            "file" => %{
              "bytes" => encoded,
              "name" => "f.bin",
              "mimeType" => "application/octet-stream"
            }
          },
          :part
        )

      assert %Part.File{kind: :file} = part
      assert part.file.bytes == "raw bytes"
      assert part.file.name == "f.bin"
      assert part.file.mime_type == "application/octet-stream"
    end

    test "decodes file part with URI" do
      {:ok, part} =
        JSON.decode(
          %{"kind" => "file", "file" => %{"uri" => "https://example.com/f"}},
          :part
        )

      assert part.file.uri == "https://example.com/f"
      assert part.file.bytes == nil
    end

    test "decodes data part" do
      {:ok, part} = JSON.decode(%{"kind" => "data", "data" => %{"x" => 1}}, :part)
      assert %Part.Data{kind: :data, data: %{"x" => 1}} = part
    end

    test "returns error for missing kind" do
      assert {:error, {:missing_field, "kind"}} = JSON.decode(%{"text" => "hi"}, :part)
    end

    test "returns error for unknown kind" do
      assert {:error, {:unknown_kind, "video"}} =
               JSON.decode(%{"kind" => "video"}, :part)
    end
  end

  describe "decode :file_content" do
    test "decodes base64 bytes" do
      encoded = Base.encode64("hello")
      {:ok, fc} = JSON.decode(%{"bytes" => encoded, "name" => "f.txt"}, :file_content)

      assert fc.bytes == "hello"
      assert fc.name == "f.txt"
    end

    test "returns error for invalid base64" do
      assert {:error, :invalid_base64} =
               JSON.decode(%{"bytes" => "not valid base64!!!"}, :file_content)
    end

    test "handles URI-only file content" do
      {:ok, fc} = JSON.decode(%{"uri" => "https://example.com/f"}, :file_content)
      assert fc.uri == "https://example.com/f"
      assert fc.bytes == nil
    end
  end

  describe "decode :message" do
    test "decodes full message" do
      map = %{
        "kind" => "message",
        "messageId" => "msg-1",
        "role" => "user",
        "parts" => [%{"kind" => "text", "text" => "hi"}],
        "taskId" => "tsk-1",
        "contextId" => "ctx-1",
        "metadata" => %{"key" => "val"}
      }

      {:ok, msg} = JSON.decode(map, :message)

      assert %Message{
               message_id: "msg-1",
               role: :user,
               task_id: "tsk-1",
               context_id: "ctx-1"
             } = msg

      assert [%Part.Text{text: "hi"}] = msg.parts
      assert msg.metadata == %{"key" => "val"}
    end

    test "returns error for missing role" do
      assert {:error, {:missing_field, "role"}} =
               JSON.decode(%{"parts" => []}, :message)
    end

    test "returns error for invalid role" do
      assert {:error, {:invalid_role, "system"}} =
               JSON.decode(%{"role" => "system", "parts" => []}, :message)
    end

    test "returns error for missing parts" do
      assert {:error, {:missing_field, "parts"}} =
               JSON.decode(%{"role" => "user"}, :message)
    end
  end

  describe "decode :artifact" do
    test "decodes full artifact" do
      map = %{
        "artifactId" => "art-1",
        "name" => "result",
        "description" => "desc",
        "parts" => [%{"kind" => "text", "text" => "output"}],
        "metadata" => %{"type" => "text"}
      }

      {:ok, artifact} = JSON.decode(map, :artifact)

      assert artifact.artifact_id == "art-1"
      assert artifact.name == "result"
      assert artifact.description == "desc"
      assert [%Part.Text{text: "output"}] = artifact.parts
      assert artifact.metadata == %{"type" => "text"}
    end

    test "returns error for missing parts" do
      assert {:error, {:missing_field, "parts"}} =
               JSON.decode(%{"artifactId" => "art-1"}, :artifact)
    end
  end

  describe "decode :status" do
    test "decodes hyphenated state" do
      {:ok, status} =
        JSON.decode(
          %{"state" => "input-required", "timestamp" => "2024-01-01T00:00:00Z"},
          :status
        )

      assert status.state == :input_required
    end

    test "decodes auth-required" do
      {:ok, status} = JSON.decode(%{"state" => "auth-required"}, :status)
      assert status.state == :auth_required
    end

    test "decodes simple state" do
      {:ok, status} = JSON.decode(%{"state" => "working"}, :status)
      assert status.state == :working
    end

    test "decodes timestamp" do
      {:ok, status} =
        JSON.decode(%{"state" => "working", "timestamp" => "2024-06-15T12:30:00Z"}, :status)

      assert %DateTime{year: 2024, month: 6, day: 15} = status.timestamp
    end

    test "handles nil timestamp" do
      {:ok, status} = JSON.decode(%{"state" => "working"}, :status)
      assert status.timestamp == nil
    end

    test "decodes nested message" do
      map = %{
        "state" => "working",
        "message" => %{
          "role" => "agent",
          "parts" => [%{"kind" => "text", "text" => "processing"}]
        }
      }

      {:ok, status} = JSON.decode(map, :status)
      assert %Message{role: :agent} = status.message
    end

    test "returns error for missing state" do
      assert {:error, {:missing_field, "state"}} = JSON.decode(%{}, :status)
    end

    test "returns error for invalid state" do
      assert {:error, {:invalid_state, "running"}} =
               JSON.decode(%{"state" => "running"}, :status)
    end

    test "returns error for invalid timestamp" do
      assert {:error, {:invalid_timestamp, "not-a-date"}} =
               JSON.decode(%{"state" => "working", "timestamp" => "not-a-date"}, :status)
    end
  end

  describe "decode :task" do
    test "decodes full task" do
      map = %{
        "kind" => "task",
        "id" => "tsk-1",
        "contextId" => "ctx-1",
        "status" => %{"state" => "completed"},
        "history" => [
          %{"role" => "user", "parts" => [%{"kind" => "text", "text" => "hello"}]}
        ],
        "artifacts" => [
          %{"parts" => [%{"kind" => "text", "text" => "result"}]}
        ],
        "metadata" => %{"source" => "test"}
      }

      {:ok, task} = JSON.decode(map, :task)

      assert task.id == "tsk-1"
      assert task.context_id == "ctx-1"
      assert task.status.state == :completed
      assert [%Message{role: :user}] = task.history
      assert [%Artifact{}] = task.artifacts
      assert task.metadata == %{"source" => "test"}
    end

    test "returns error for missing id" do
      assert {:error, {:missing_field, "id"}} =
               JSON.decode(%{"status" => %{"state" => "working"}}, :task)
    end

    test "returns error for missing status" do
      assert {:error, {:missing_field, "status"}} =
               JSON.decode(%{"id" => "tsk-1"}, :task)
    end

    test "defaults empty history and artifacts" do
      {:ok, task} = JSON.decode(%{"id" => "tsk-1", "status" => %{"state" => "submitted"}}, :task)
      assert task.history == []
      assert task.artifacts == []
    end
  end

  describe "decode :event" do
    test "dispatches status-update" do
      map = %{
        "kind" => "status-update",
        "taskId" => "tsk-1",
        "status" => %{"state" => "working"},
        "final" => false
      }

      {:ok, event} = JSON.decode(map, :event)
      assert %StatusUpdate{task_id: "tsk-1"} = event
    end

    test "dispatches artifact-update" do
      map = %{
        "kind" => "artifact-update",
        "taskId" => "tsk-1",
        "artifact" => %{"parts" => [%{"kind" => "text", "text" => "x"}]}
      }

      {:ok, event} = JSON.decode(map, :event)
      assert %ArtifactUpdate{task_id: "tsk-1"} = event
    end

    test "dispatches task" do
      map = %{
        "kind" => "task",
        "id" => "tsk-1",
        "status" => %{"state" => "completed"}
      }

      {:ok, task} = JSON.decode(map, :event)
      assert %Task{id: "tsk-1"} = task
    end

    test "dispatches message" do
      map = %{
        "kind" => "message",
        "role" => "agent",
        "parts" => [%{"kind" => "text", "text" => "hi"}]
      }

      {:ok, msg} = JSON.decode(map, :event)
      assert %Message{role: :agent} = msg
    end

    test "returns error for missing kind" do
      assert {:error, {:missing_field, "kind"}} = JSON.decode(%{}, :event)
    end

    test "returns error for unknown kind" do
      assert {:error, {:unknown_kind, "stream"}} =
               JSON.decode(%{"kind" => "stream"}, :event)
    end
  end

  describe "decode :status_update_event" do
    test "decodes full event" do
      map = %{
        "kind" => "status-update",
        "taskId" => "tsk-1",
        "contextId" => "ctx-1",
        "status" => %{"state" => "completed"},
        "final" => true,
        "metadata" => %{"reason" => "done"}
      }

      {:ok, event} = JSON.decode(map, :status_update_event)

      assert event.task_id == "tsk-1"
      assert event.context_id == "ctx-1"
      assert event.status.state == :completed
      assert event.final == true
      assert event.metadata == %{"reason" => "done"}
    end

    test "returns error for missing taskId" do
      assert {:error, {:missing_field, "taskId"}} =
               JSON.decode(
                 %{"status" => %{"state" => "working"}, "final" => false},
                 :status_update_event
               )
    end
  end

  describe "decode :artifact_update_event" do
    test "decodes full event" do
      map = %{
        "kind" => "artifact-update",
        "taskId" => "tsk-1",
        "contextId" => "ctx-1",
        "artifact" => %{"parts" => [%{"kind" => "text", "text" => "chunk"}]},
        "append" => true,
        "lastChunk" => true,
        "metadata" => %{"seq" => 1}
      }

      {:ok, event} = JSON.decode(map, :artifact_update_event)

      assert event.task_id == "tsk-1"
      assert event.context_id == "ctx-1"
      assert event.append == true
      assert event.last_chunk == true
      assert [%Part.Text{text: "chunk"}] = event.artifact.parts
    end
  end

  # -------------------------------------------------------------------
  # Round-trips
  # -------------------------------------------------------------------

  describe "round-trip" do
    test "Part.Text" do
      original = Part.Text.new("hello", %{"lang" => "en"})
      assert original == original |> JSON.encode!() |> JSON.decode!(:part)
    end

    test "Part.Data" do
      original = Part.Data.new(%{"key" => "val"})
      assert original == original |> JSON.encode!() |> JSON.decode!(:part)
    end

    test "Part.File with bytes" do
      fc =
        FileContent.from_bytes("binary data",
          name: "f.bin",
          mime_type: "application/octet-stream"
        )

      original = Part.File.new(fc)
      assert original == original |> JSON.encode!() |> JSON.decode!(:part)
    end

    test "Part.File with URI" do
      fc = FileContent.from_uri("https://example.com/f", name: "f.pdf")
      original = Part.File.new(fc)
      assert original == original |> JSON.encode!() |> JSON.decode!(:part)
    end

    test "FileContent" do
      original =
        FileContent.from_bytes(<<1, 2, 3>>,
          name: "test.bin",
          mime_type: "application/octet-stream"
        )

      assert original == original |> JSON.encode!() |> JSON.decode!(:file_content)
    end

    test "Message" do
      original = %Message{
        message_id: "msg-1",
        role: :user,
        parts: [Part.Text.new("hello")],
        task_id: "tsk-1",
        context_id: "ctx-1",
        metadata: %{"key" => "val"}
      }

      assert original == original |> JSON.encode!() |> JSON.decode!(:message)
    end

    test "Artifact" do
      original = %Artifact{
        artifact_id: "art-1",
        name: "result",
        description: "desc",
        parts: [Part.Text.new("output"), Part.Data.new(%{"x" => 1})],
        metadata: %{"type" => "text"}
      }

      assert original == original |> JSON.encode!() |> JSON.decode!(:artifact)
    end

    test "Task.Status" do
      original = Task.Status.new(:input_required)
      decoded = original |> JSON.encode!() |> JSON.decode!(:status)
      assert decoded.state == original.state
      # Timestamps lose microsecond precision in ISO8601 round-trip,
      # so we compare truncated values
      assert DateTime.truncate(decoded.timestamp, :second) ==
               DateTime.truncate(original.timestamp, :second)
    end

    test "Task" do
      msg = %Message{
        message_id: "msg-1",
        role: :user,
        parts: [Part.Text.new("hello")]
      }

      task = %Task{
        id: "tsk-1",
        context_id: "ctx-1",
        status: Task.Status.new(:completed),
        history: [msg],
        artifacts: [%Artifact{parts: [Part.Text.new("result")]}],
        metadata: %{"key" => "val"}
      }

      decoded = task |> JSON.encode!() |> JSON.decode!(:task)
      assert decoded.id == task.id
      assert decoded.context_id == task.context_id
      assert decoded.status.state == task.status.state
      assert length(decoded.history) == 1
      assert length(decoded.artifacts) == 1
      assert decoded.metadata == task.metadata
    end

    test "StatusUpdate event" do
      status = Task.Status.new(:working)
      original = StatusUpdate.new("tsk-1", status, context_id: "ctx-1", final: false)
      decoded = original |> JSON.encode!() |> JSON.decode!(:status_update_event)

      assert decoded.task_id == original.task_id
      assert decoded.context_id == original.context_id
      assert decoded.final == original.final
      assert decoded.status.state == original.status.state
    end

    test "ArtifactUpdate event" do
      artifact = %Artifact{
        artifact_id: "art-1",
        parts: [Part.Text.new("chunk")],
        metadata: %{"seq" => 1}
      }

      original =
        ArtifactUpdate.new("tsk-1", artifact,
          context_id: "ctx-1",
          append: true,
          last_chunk: false
        )

      decoded = original |> JSON.encode!() |> JSON.decode!(:artifact_update_event)

      assert decoded.task_id == original.task_id
      assert decoded.context_id == original.context_id
      assert decoded.append == original.append
      assert decoded.last_chunk == original.last_chunk
      assert decoded.artifact.artifact_id == original.artifact.artifact_id
    end
  end

  # -------------------------------------------------------------------
  # Bang variants
  # -------------------------------------------------------------------

  describe "encode!/1" do
    test "returns map on success" do
      map = JSON.encode!(Part.Text.new("hi"))
      assert %{"kind" => "text", "text" => "hi"} = map
    end

    test "raises on error" do
      assert_raise ArgumentError, ~r/encode failed/, fn ->
        JSON.encode!(URI.parse("http://example.com"))
      end
    end
  end

  describe "decode!/2" do
    test "returns struct on success" do
      part = JSON.decode!(%{"kind" => "text", "text" => "hi"}, :part)
      assert %Part.Text{text: "hi"} = part
    end

    test "raises on error" do
      assert_raise ArgumentError, ~r/decode failed/, fn ->
        JSON.decode!(%{}, :status)
      end
    end
  end

  # -------------------------------------------------------------------
  # AgentCard
  # -------------------------------------------------------------------

  describe "encode_agent_card/2" do
    test "encodes minimal card" do
      card = %{
        name: "test-agent",
        description: "A test agent",
        version: "1.0.0",
        skills: [
          %{id: "greet", name: "Greet", description: "Says hello", tags: ["greeting"]}
        ],
        opts: []
      }

      map = JSON.encode_agent_card(card, url: "https://example.com/a2a")

      assert map["name"] == "test-agent"
      assert map["description"] == "A test agent"
      assert map["url"] == "https://example.com/a2a"
      assert map["version"] == "1.0.0"
      assert [%{"id" => "greet", "tags" => ["greeting"]}] = map["skills"]
      assert map["capabilities"] == %{}
      assert map["defaultInputModes"] == ["text/plain"]
      assert map["defaultOutputModes"] == ["text/plain"]
      refute Map.has_key?(map, "provider")
    end

    test "encodes full card with all options" do
      card = %{
        name: "full-agent",
        description: "Full agent",
        version: "2.0.0",
        skills: [],
        opts: []
      }

      map =
        JSON.encode_agent_card(card,
          url: "https://example.com/a2a",
          capabilities: %{streaming: true, push_notifications: false},
          default_input_modes: ["text/plain", "application/json"],
          default_output_modes: ["text/plain"],
          provider: %{organization: "Acme", url: "https://acme.example.com"},
          documentation_url: "https://docs.example.com",
          icon_url: "https://example.com/icon.png",
          protocol_version: "0.3"
        )

      assert map["capabilities"] == %{"streaming" => true, "pushNotifications" => false}
      assert map["defaultInputModes"] == ["text/plain", "application/json"]
      assert map["provider"] == %{"organization" => "Acme", "url" => "https://acme.example.com"}
      assert map["documentationUrl"] == "https://docs.example.com"
      assert map["iconUrl"] == "https://example.com/icon.png"
      assert map["protocolVersion"] == "0.3"
    end

    test "raises when url is missing" do
      card = %{name: "x", description: "x", version: "1.0.0", skills: [], opts: []}

      assert_raise KeyError, ~r/:url/, fn ->
        JSON.encode_agent_card(card, [])
      end
    end
  end

  # -------------------------------------------------------------------
  # Error propagation in nested structures
  # -------------------------------------------------------------------

  describe "error propagation" do
    test "invalid part in message parts list" do
      map = %{
        "role" => "user",
        "parts" => [%{"kind" => "text", "text" => "ok"}, %{"kind" => "unknown"}]
      }

      assert {:error, {:unknown_kind, "unknown"}} = JSON.decode(map, :message)
    end

    test "invalid base64 in file part" do
      map = %{
        "kind" => "file",
        "file" => %{"bytes" => "!!!not-base64!!!"}
      }

      assert {:error, :invalid_base64} = JSON.decode(map, :part)
    end

    test "invalid state in task status" do
      map = %{
        "id" => "tsk-1",
        "status" => %{"state" => "running"}
      }

      assert {:error, {:invalid_state, "running"}} = JSON.decode(map, :task)
    end
  end
end
