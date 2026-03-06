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
      assert map["role"] == "ROLE_USER"
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
    test "encodes state atoms to v0.3 TASK_STATE_* format" do
      status = Task.Status.new(:input_required)
      {:ok, map} = JSON.encode(status)
      assert map["state"] == "TASK_STATE_INPUT_REQUIRED"
    end

    test "encodes auth_required" do
      status = Task.Status.new(:auth_required)
      {:ok, map} = JSON.encode(status)
      assert map["state"] == "TASK_STATE_AUTH_REQUIRED"
    end

    test "encodes simple state as v0.3 format" do
      status = Task.Status.new(:working)
      {:ok, map} = JSON.encode(status)
      assert map["state"] == "TASK_STATE_WORKING"
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
      assert map["message"]["role"] == "ROLE_AGENT"
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
      assert map["status"]["state"] == "TASK_STATE_SUBMITTED"
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
      assert map["status"]["state"] == "TASK_STATE_WORKING"
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
      assert %Part.Text{text: "hello", metadata: %{}} = part
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

      assert %Part.File{} = part
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
      assert %Part.Data{data: %{"x" => 1}} = part
    end

    test "infers text part when kind is absent" do
      {:ok, part} = JSON.decode(%{"text" => "hi"}, :part)
      assert %Part.Text{text: "hi"} = part
    end

    test "infers file part when kind is absent" do
      {:ok, part} = JSON.decode(%{"file" => %{"uri" => "https://example.com/f"}}, :part)
      assert %Part.File{} = part
    end

    test "infers data part when kind is absent" do
      {:ok, part} = JSON.decode(%{"data" => %{"x" => 1}}, :part)
      assert %Part.Data{data: %{"x" => 1}} = part
    end

    test "returns error when kind is absent and no content field" do
      assert {:error, {:missing_field, "kind"}} = JSON.decode(%{"metadata" => %{}}, :part)
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

    test "accepts v1.0 field names as aliases" do
      encoded = Base.encode64("hello")

      {:ok, fc} =
        JSON.decode(
          %{
            "fileWithBytes" => encoded,
            "fileWithUri" => "https://example.com/f",
            "mediaType" => "text/plain",
            "name" => "f.txt"
          },
          :file_content
        )

      assert fc.bytes == "hello"
      assert fc.uri == "https://example.com/f"
      assert fc.mime_type == "text/plain"
      assert fc.name == "f.txt"
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

    test "decodes v0.3 ROLE_USER format" do
      map = %{
        "role" => "ROLE_USER",
        "parts" => [%{"text" => "hi"}]
      }

      {:ok, msg} = JSON.decode(map, :message)
      assert msg.role == :user
    end

    test "decodes v0.3 ROLE_AGENT format" do
      map = %{
        "role" => "ROLE_AGENT",
        "parts" => [%{"text" => "hi"}]
      }

      {:ok, msg} = JSON.decode(map, :message)
      assert msg.role == :agent
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
    test "decodes v0.3 TASK_STATE_* format" do
      {:ok, status} =
        JSON.decode(
          %{"state" => "TASK_STATE_INPUT_REQUIRED", "timestamp" => "2024-01-01T00:00:00Z"},
          :status
        )

      assert status.state == :input_required
    end

    test "decodes v0.3 TASK_STATE_AUTH_REQUIRED" do
      {:ok, status} = JSON.decode(%{"state" => "TASK_STATE_AUTH_REQUIRED"}, :status)
      assert status.state == :auth_required
    end

    test "decodes v0.3 TASK_STATE_WORKING" do
      {:ok, status} = JSON.decode(%{"state" => "TASK_STATE_WORKING"}, :status)
      assert status.state == :working
    end

    test "still accepts legacy hyphenated state" do
      {:ok, status} = JSON.decode(%{"state" => "input-required"}, :status)
      assert status.state == :input_required
    end

    test "still accepts legacy lowercase state" do
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

      assert [
               %{
                 "url" => "https://example.com/a2a",
                 "protocolBinding" => "jsonrpc",
                 "protocolVersion" => "2.0"
               }
             ] = map["supportedInterfaces"]

      refute Map.has_key?(map, "provider")
    end

    test "accepts custom supported_interfaces" do
      card = %{
        name: "test-agent",
        description: "A test agent",
        version: "1.0.0",
        skills: [],
        opts: []
      }

      interfaces = [
        %{url: "https://a.example.com", protocol_binding: "jsonrpc", protocol_version: "2.0"},
        %{url: "https://b.example.com", protocol_binding: "grpc", protocol_version: "1.0"}
      ]

      map =
        JSON.encode_agent_card(card,
          url: "https://example.com/a2a",
          supported_interfaces: interfaces
        )

      assert [first, second] = map["supportedInterfaces"]
      assert first["url"] == "https://a.example.com"
      assert first["protocolBinding"] == "jsonrpc"
      assert second["url"] == "https://b.example.com"
      assert second["protocolBinding"] == "grpc"
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
      assert [%{"url" => "https://example.com/a2a"}] = map["supportedInterfaces"]
    end

    test "raises when url is missing" do
      card = %{name: "x", description: "x", version: "1.0.0", skills: [], opts: []}

      assert_raise KeyError, ~r/:url/, fn ->
        JSON.encode_agent_card(card, [])
      end
    end
  end

  # -------------------------------------------------------------------
  # AgentCard decoding
  # -------------------------------------------------------------------

  describe "decode_agent_card/1" do
    test "decodes minimal card" do
      map = %{
        "name" => "test-agent",
        "description" => "A test agent",
        "url" => "https://example.com/a2a",
        "version" => "1.0.0",
        "skills" => [
          %{
            "id" => "greet",
            "name" => "Greet",
            "description" => "Says hello",
            "tags" => ["greeting"]
          }
        ]
      }

      {:ok, card} = JSON.decode_agent_card(map)

      assert card.name == "test-agent"
      assert card.description == "A test agent"
      assert card.url == "https://example.com/a2a"
      assert card.version == "1.0.0"
      assert [%{id: "greet", name: "Greet", tags: ["greeting"]}] = card.skills
      assert card.capabilities == %{}
      assert card.default_input_modes == ["text/plain"]
      assert card.default_output_modes == ["text/plain"]
      assert card.supported_interfaces == []
      assert card.provider == nil
    end

    test "decodes full card with all optional fields" do
      map = %{
        "name" => "full-agent",
        "description" => "Full agent",
        "url" => "https://example.com/a2a",
        "version" => "2.0.0",
        "skills" => [],
        "capabilities" => %{
          "streaming" => true,
          "pushNotifications" => false,
          "stateTransitionHistory" => true
        },
        "defaultInputModes" => ["text/plain", "application/json"],
        "defaultOutputModes" => ["text/plain"],
        "supportedInterfaces" => [
          %{
            "url" => "https://example.com/a2a",
            "protocolBinding" => "jsonrpc",
            "protocolVersion" => "2.0"
          }
        ],
        "provider" => %{
          "organization" => "Acme",
          "url" => "https://acme.example.com"
        },
        "documentationUrl" => "https://docs.example.com",
        "iconUrl" => "https://example.com/icon.png",
        "protocolVersion" => "0.3"
      }

      {:ok, card} = JSON.decode_agent_card(map)

      assert card.capabilities == %{
               streaming: true,
               push_notifications: false,
               state_transition_history: true
             }

      assert card.default_input_modes == ["text/plain", "application/json"]

      assert [
               %{
                 url: "https://example.com/a2a",
                 protocol_binding: "jsonrpc",
                 protocol_version: "2.0"
               }
             ] = card.supported_interfaces

      assert card.provider == %{organization: "Acme", url: "https://acme.example.com"}
      assert card.documentation_url == "https://docs.example.com"
      assert card.icon_url == "https://example.com/icon.png"
      assert card.protocol_version == "0.3"
    end

    test "returns error for missing required field" do
      assert {:error, {:missing_field, "name"}} =
               JSON.decode_agent_card(%{
                 "description" => "x",
                 "url" => "x",
                 "version" => "1",
                 "skills" => []
               })
    end

    test "returns error for missing skill field" do
      assert {:error, {:missing_field, "id"}} =
               JSON.decode_agent_card(%{
                 "name" => "x",
                 "description" => "x",
                 "url" => "x",
                 "version" => "1",
                 "skills" => [%{"name" => "s", "description" => "d"}]
               })
    end

    test "roundtrip encode_agent_card -> decode_agent_card" do
      card = %{
        name: "roundtrip",
        description: "Roundtrip test",
        version: "1.0.0",
        skills: [
          %{id: "s1", name: "Skill One", description: "Does stuff", tags: ["tag1"]}
        ],
        opts: []
      }

      encoded =
        JSON.encode_agent_card(card,
          url: "https://example.com",
          capabilities: %{streaming: true},
          provider: %{organization: "Org", url: "https://org.example.com"},
          documentation_url: "https://docs.example.com",
          icon_url: "https://icon.example.com",
          protocol_version: "0.3"
        )

      {:ok, decoded} = JSON.decode_agent_card(encoded)

      assert decoded.name == "roundtrip"
      assert decoded.description == "Roundtrip test"
      assert decoded.url == "https://example.com"
      assert decoded.version == "1.0.0"
      assert [%{id: "s1", name: "Skill One", tags: ["tag1"]}] = decoded.skills
      assert decoded.capabilities == %{streaming: true}

      assert [%{url: "https://example.com", protocol_binding: "jsonrpc", protocol_version: "2.0"}] =
               decoded.supported_interfaces

      assert decoded.provider == %{organization: "Org", url: "https://org.example.com"}
      assert decoded.documentation_url == "https://docs.example.com"
      assert decoded.icon_url == "https://icon.example.com"
      assert decoded.protocol_version == "0.3"
    end
  end

  # -------------------------------------------------------------------
  # Security Schemes
  # -------------------------------------------------------------------

  describe "encode_agent_card with security schemes" do
    test "omits securitySchemes when empty" do
      card = %{name: "x", description: "x", version: "1", skills: [], opts: []}
      map = JSON.encode_agent_card(card, url: "https://example.com")
      refute Map.has_key?(map, "securitySchemes")
      refute Map.has_key?(map, "security")
    end

    test "encodes all 5 scheme types" do
      card = %{name: "x", description: "x", version: "1", skills: [], opts: []}

      schemes = %{
        "apikey" => %A2A.SecurityScheme.APIKey{name: "x-api-key", in: "header"},
        "bearer" => %A2A.SecurityScheme.HTTPAuth{scheme: "bearer"},
        "oauth" => %A2A.SecurityScheme.OAuth2{
          flows: %{"authorizationCode" => %{"authorizationUrl" => "https://auth.example.com"}},
          oauth2_metadata_url: "https://auth.example.com/.well-known/oauth"
        },
        "oidc" => %A2A.SecurityScheme.OpenIDConnect{
          open_id_connect_url: "https://auth.example.com/.well-known/openid-configuration"
        },
        "mtls" => %A2A.SecurityScheme.MutualTLS{}
      }

      security = [%{"bearer" => []}]

      map =
        JSON.encode_agent_card(card,
          url: "https://example.com",
          security_schemes: schemes,
          security: security
        )

      assert %{
               "apiKeySecurityScheme" => %{
                 "name" => "x-api-key",
                 "in" => "header"
               }
             } = map["securitySchemes"]["apikey"]

      assert %{
               "httpAuthSecurityScheme" => %{"scheme" => "bearer"}
             } = map["securitySchemes"]["bearer"]

      assert %{
               "oauth2SecurityScheme" => %{
                 "flows" => %{"authorizationCode" => _},
                 "oauth2MetadataUrl" => "https://auth.example.com/.well-known/oauth"
               }
             } = map["securitySchemes"]["oauth"]

      assert %{
               "openIdConnectSecurityScheme" => %{
                 "openIdConnectUrl" => "https://auth.example.com/.well-known/openid-configuration"
               }
             } = map["securitySchemes"]["oidc"]

      assert %{"mtlsSecurityScheme" => %{}} = map["securitySchemes"]["mtls"]

      assert map["security"] == [%{"bearer" => []}]
    end

    test "encodes extendedAgentCard capability" do
      card = %{name: "x", description: "x", version: "1", skills: [], opts: []}

      map =
        JSON.encode_agent_card(card,
          url: "https://example.com",
          capabilities: %{extended_agent_card: true}
        )

      assert map["capabilities"]["extendedAgentCard"] == true
    end
  end

  describe "decode_agent_card with security schemes" do
    test "decodes all 5 scheme types" do
      map = %{
        "name" => "x",
        "description" => "x",
        "url" => "https://example.com",
        "version" => "1",
        "skills" => [],
        "securitySchemes" => %{
          "apikey" => %{
            "apiKeySecurityScheme" => %{"name" => "x-api-key", "in" => "header"}
          },
          "bearer" => %{
            "httpAuthSecurityScheme" => %{"scheme" => "bearer"}
          },
          "oauth" => %{
            "oauth2SecurityScheme" => %{
              "flows" => %{"authorizationCode" => %{}},
              "oauth2MetadataUrl" => "https://meta.example.com"
            }
          },
          "oidc" => %{
            "openIdConnectSecurityScheme" => %{
              "openIdConnectUrl" => "https://oidc.example.com"
            }
          },
          "mtls" => %{"mtlsSecurityScheme" => %{}}
        },
        "security" => [%{"bearer" => []}, %{"apikey" => []}]
      }

      {:ok, card} = JSON.decode_agent_card(map)

      assert %A2A.SecurityScheme.APIKey{name: "x-api-key", in: "header"} =
               card.security_schemes["apikey"]

      assert %A2A.SecurityScheme.HTTPAuth{scheme: "bearer"} =
               card.security_schemes["bearer"]

      assert %A2A.SecurityScheme.OAuth2{
               flows: %{"authorizationCode" => %{}},
               oauth2_metadata_url: "https://meta.example.com"
             } = card.security_schemes["oauth"]

      assert %A2A.SecurityScheme.OpenIDConnect{
               open_id_connect_url: "https://oidc.example.com"
             } = card.security_schemes["oidc"]

      assert %A2A.SecurityScheme.MutualTLS{} = card.security_schemes["mtls"]

      assert card.security == [%{"bearer" => []}, %{"apikey" => []}]
    end

    test "defaults to empty when absent" do
      map = %{
        "name" => "x",
        "description" => "x",
        "url" => "https://example.com",
        "version" => "1",
        "skills" => []
      }

      {:ok, card} = JSON.decode_agent_card(map)
      assert card.security_schemes == %{}
      assert card.security == []
    end

    test "decodes extendedAgentCard capability" do
      map = %{
        "name" => "x",
        "description" => "x",
        "url" => "https://example.com",
        "version" => "1",
        "skills" => [],
        "capabilities" => %{"extendedAgentCard" => true}
      }

      {:ok, card} = JSON.decode_agent_card(map)
      assert card.capabilities.extended_agent_card == true
    end

    test "roundtrip with security schemes" do
      card = %{
        name: "secure-agent",
        description: "Agent with security",
        version: "1.0.0",
        skills: [
          %{id: "s1", name: "Skill", description: "Does things", tags: []}
        ],
        opts: []
      }

      schemes = %{
        "bearer" => %A2A.SecurityScheme.HTTPAuth{scheme: "bearer"},
        "apikey" => %A2A.SecurityScheme.APIKey{name: "x-api-key", in: "header"}
      }

      security = [%{"bearer" => []}]

      encoded =
        JSON.encode_agent_card(card,
          url: "https://example.com",
          security_schemes: schemes,
          security: security,
          capabilities: %{extended_agent_card: true, streaming: true}
        )

      {:ok, decoded} = JSON.decode_agent_card(encoded)

      assert decoded.name == "secure-agent"
      assert decoded.security_schemes == schemes
      assert decoded.security == security
      assert decoded.capabilities.extended_agent_card == true
      assert decoded.capabilities.streaming == true
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
