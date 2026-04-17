defmodule A2A.V1DataModelTest do
  @moduledoc """
  Tests for v1.0 data model fields added from the proto spec.
  Verifies encode/decode round-trip for all new fields and structs.
  """

  use ExUnit.Case, async: true

  alias A2A.JSON

  # -------------------------------------------------------------------
  # New Structs
  # -------------------------------------------------------------------

  describe "AuthenticationInfo" do
    test "struct creation" do
      auth = %A2A.AuthenticationInfo{scheme: "Bearer", credentials: "token123"}
      assert auth.scheme == "Bearer"
      assert auth.credentials == "token123"
    end

    test "encode/decode round-trip" do
      auth = %A2A.AuthenticationInfo{scheme: "Bearer", credentials: "tok"}
      {:ok, map} = JSON.encode(auth)
      assert map == %{"scheme" => "Bearer", "credentials" => "tok"}

      {:ok, decoded} = JSON.decode(map, :authentication_info)
      assert decoded.scheme == "Bearer"
      assert decoded.credentials == "tok"
    end

    test "encode omits nil credentials" do
      auth = %A2A.AuthenticationInfo{scheme: "Basic"}
      {:ok, map} = JSON.encode(auth)
      assert map == %{"scheme" => "Basic"}
      refute Map.has_key?(map, "credentials")
    end
  end

  describe "AgentExtension" do
    test "struct creation with defaults" do
      ext = %A2A.AgentExtension{uri: "urn:a2a:ext:test"}
      assert ext.uri == "urn:a2a:ext:test"
      assert ext.required == false
      assert ext.description == nil
      assert ext.params == nil
    end

    test "encode/decode round-trip" do
      ext = %A2A.AgentExtension{
        uri: "urn:a2a:ext:test",
        description: "A test extension",
        required: true,
        params: %{"key" => "value"}
      }

      {:ok, map} = JSON.encode(ext)
      assert map["uri"] == "urn:a2a:ext:test"
      assert map["description"] == "A test extension"
      assert map["required"] == true
      assert map["params"] == %{"key" => "value"}
    end

    test "encode omits false required and nil fields" do
      ext = %A2A.AgentExtension{uri: "urn:a2a:ext:simple"}
      {:ok, map} = JSON.encode(ext)
      assert map == %{"uri" => "urn:a2a:ext:simple"}
      refute Map.has_key?(map, "required")
      refute Map.has_key?(map, "description")
      refute Map.has_key?(map, "params")
    end
  end

  describe "AgentCardSignature" do
    test "struct creation" do
      sig = %A2A.AgentCardSignature{
        protected: "eyJhbGciOiJSUzI1NiJ9",
        signature: "abc123"
      }

      assert sig.protected == "eyJhbGciOiJSUzI1NiJ9"
      assert sig.signature == "abc123"
      assert sig.header == nil
    end

    test "encode/decode round-trip" do
      sig = %A2A.AgentCardSignature{
        protected: "eyJhbGciOiJSUzI1NiJ9",
        signature: "abc123",
        header: %{"kid" => "key-1"}
      }

      {:ok, map} = JSON.encode(sig)
      assert map["protected"] == "eyJhbGciOiJSUzI1NiJ9"
      assert map["signature"] == "abc123"
      assert map["header"] == %{"kid" => "key-1"}
    end
  end

  describe "TaskPushNotificationConfig" do
    test "struct creation" do
      config = %A2A.TaskPushNotificationConfig{
        url: "https://webhook.example.com/notify",
        task_id: "task-1",
        token: "secret"
      }

      assert config.url == "https://webhook.example.com/notify"
      assert config.task_id == "task-1"
      assert config.tenant == nil
    end

    test "encode/decode round-trip" do
      config = %A2A.TaskPushNotificationConfig{
        tenant: "tenant-1",
        id: "config-1",
        task_id: "task-1",
        url: "https://hook.example.com",
        token: "tok",
        authentication: %A2A.AuthenticationInfo{scheme: "Bearer", credentials: "jwt"}
      }

      {:ok, map} = JSON.encode(config)
      assert map["url"] == "https://hook.example.com"
      assert map["tenant"] == "tenant-1"
      assert map["id"] == "config-1"
      assert map["taskId"] == "task-1"
      assert map["token"] == "tok"
      assert map["authentication"]["scheme"] == "Bearer"

      {:ok, decoded} = JSON.decode(map, :push_notification_config)
      assert decoded.url == "https://hook.example.com"
      assert decoded.tenant == "tenant-1"
      assert decoded.id == "config-1"
      assert decoded.task_id == "task-1"
      assert decoded.token == "tok"
      assert decoded.authentication.scheme == "Bearer"
      assert decoded.authentication.credentials == "jwt"
    end

    test "encode omits nil optional fields" do
      config = %A2A.TaskPushNotificationConfig{url: "https://hook.example.com"}
      {:ok, map} = JSON.encode(config)
      assert map == %{"url" => "https://hook.example.com"}
    end
  end

  describe "SendMessageConfiguration" do
    test "struct defaults" do
      config = %A2A.SendMessageConfiguration{}
      assert config.accepted_output_modes == []
      assert config.task_push_notification_config == nil
      assert config.history_length == nil
      assert config.return_immediately == false
    end

    test "encode/decode round-trip" do
      config = %A2A.SendMessageConfiguration{
        accepted_output_modes: ["text/plain", "application/json"],
        history_length: 10,
        return_immediately: true
      }

      {:ok, map} = JSON.encode(config)
      assert map["acceptedOutputModes"] == ["text/plain", "application/json"]
      assert map["historyLength"] == 10
      assert map["returnImmediately"] == true

      {:ok, decoded} = JSON.decode(map, :send_message_configuration)
      assert decoded.accepted_output_modes == ["text/plain", "application/json"]
      assert decoded.history_length == 10
      assert decoded.return_immediately == true
    end

    test "encode omits empty/default fields" do
      config = %A2A.SendMessageConfiguration{}
      {:ok, map} = JSON.encode(config)
      assert map == %{}
    end

    test "with push notification config" do
      config = %A2A.SendMessageConfiguration{
        accepted_output_modes: ["text/plain"],
        task_push_notification_config: %A2A.TaskPushNotificationConfig{
          url: "https://hook.example.com",
          token: "tok"
        }
      }

      {:ok, map} = JSON.encode(config)
      assert map["taskPushNotificationConfig"]["url"] == "https://hook.example.com"

      {:ok, decoded} = JSON.decode(map, :send_message_configuration)
      assert decoded.task_push_notification_config.url == "https://hook.example.com"
      assert decoded.task_push_notification_config.token == "tok"
    end
  end

  # -------------------------------------------------------------------
  # Updated Structs — New Fields
  # -------------------------------------------------------------------

  describe "Message extensions and reference_task_ids" do
    test "encode includes reference_task_ids when non-empty" do
      msg = %A2A.Message{
        message_id: "msg-1",
        role: :user,
        parts: [A2A.Part.Text.new("hello")],
        reference_task_ids: ["task-1", "task-2"],
        extensions: ["urn:ext:1"]
      }

      {:ok, map} = JSON.encode(msg)
      assert map["referenceTaskIds"] == ["task-1", "task-2"]
      assert map["extensions"] == ["urn:ext:1"]
    end

    test "encode omits empty reference_task_ids and extensions" do
      msg = A2A.Message.new_user("hello")
      {:ok, map} = JSON.encode(msg)
      refute Map.has_key?(map, "referenceTaskIds")
      refute Map.has_key?(map, "extensions")
    end

    test "decode extracts reference_task_ids" do
      map = %{
        "messageId" => "msg-1",
        "role" => "ROLE_USER",
        "parts" => [%{"kind" => "text", "text" => "hi"}],
        "referenceTaskIds" => ["task-a"],
        "extensions" => ["urn:ext:1"]
      }

      {:ok, msg} = JSON.decode(map, :message)
      assert msg.reference_task_ids == ["task-a"]
      assert msg.extensions == ["urn:ext:1"]
    end
  end

  describe "Artifact extensions" do
    test "encode includes extensions when non-empty" do
      artifact = %A2A.Artifact{
        artifact_id: "art-1",
        parts: [A2A.Part.Text.new("result")],
        extensions: ["urn:ext:1"]
      }

      {:ok, map} = JSON.encode(artifact)
      assert map["extensions"] == ["urn:ext:1"]
    end

    test "decode extracts extensions" do
      map = %{
        "artifactId" => "art-1",
        "parts" => [%{"kind" => "text", "text" => "result"}],
        "extensions" => ["urn:ext:artifact"]
      }

      {:ok, artifact} = JSON.decode(map, :artifact)
      assert artifact.extensions == ["urn:ext:artifact"]
    end
  end

  describe "Part media_type and filename" do
    test "text part with media_type and filename" do
      part = %A2A.Part.Text{text: "hello", media_type: "text/plain", filename: "hello.txt"}
      {:ok, map} = JSON.encode(part)
      assert map["mediaType"] == "text/plain"
      assert map["filename"] == "hello.txt"

      {:ok, decoded} = JSON.decode(map, :part)
      assert decoded.media_type == "text/plain"
      assert decoded.filename == "hello.txt"
    end

    test "file part with media_type and filename" do
      file = A2A.FileContent.from_uri("https://example.com/doc.pdf")

      part = %A2A.Part.File{
        file: file,
        media_type: "application/pdf",
        filename: "doc.pdf"
      }

      {:ok, map} = JSON.encode(part)
      assert map["mediaType"] == "application/pdf"
      assert map["filename"] == "doc.pdf"
    end

    test "data part with media_type" do
      part = %A2A.Part.Data{data: %{"key" => "val"}, media_type: "application/json"}
      {:ok, map} = JSON.encode(part)
      assert map["mediaType"] == "application/json"
    end

    test "encode omits nil media_type and filename" do
      part = A2A.Part.Text.new("plain")
      {:ok, map} = JSON.encode(part)
      refute Map.has_key?(map, "mediaType")
      refute Map.has_key?(map, "filename")
    end
  end

  describe "v1.0 flat Part format decoding" do
    test "decode flat Part with raw bytes" do
      raw_b64 = Base.encode64("binary content")

      map = %{
        "raw" => raw_b64,
        "mediaType" => "application/octet-stream",
        "filename" => "data.bin"
      }

      {:ok, part} = JSON.decode(map, :part)
      assert %A2A.Part.File{} = part
      assert part.file.bytes == "binary content"
      assert part.file.mime_type == "application/octet-stream"
      assert part.file.name == "data.bin"
      assert part.media_type == "application/octet-stream"
      assert part.filename == "data.bin"
    end

    test "decode flat Part with url" do
      map = %{
        "url" => "https://example.com/image.png",
        "mediaType" => "image/png",
        "filename" => "image.png"
      }

      {:ok, part} = JSON.decode(map, :part)
      assert %A2A.Part.File{} = part
      assert part.file.uri == "https://example.com/image.png"
      assert part.file.mime_type == "image/png"
      assert part.media_type == "image/png"
      assert part.filename == "image.png"
    end

    test "v0.3 format still works (kind-based)" do
      map = %{"kind" => "text", "text" => "hello"}
      {:ok, part} = JSON.decode(map, :part)
      assert %A2A.Part.Text{text: "hello"} = part
    end

    test "v0.3 format without kind still works (inference)" do
      map = %{"text" => "hello"}
      {:ok, part} = JSON.decode(map, :part)
      assert %A2A.Part.Text{text: "hello"} = part
    end
  end

  # -------------------------------------------------------------------
  # AgentCard — New Fields
  # -------------------------------------------------------------------

  describe "AgentCard signatures" do
    test "struct defaults" do
      card = %A2A.AgentCard{
        name: "test",
        description: "test agent",
        url: "https://example.com",
        version: "1.0",
        skills: []
      }

      assert card.signatures == []
      assert card.security_requirements == []
    end

    test "decode agent card with signatures" do
      map = %{
        "name" => "test",
        "description" => "test agent",
        "url" => "https://example.com",
        "version" => "1.0",
        "skills" => [],
        "signatures" => [
          %{
            "protected" => "eyJhbGciOiJSUzI1NiJ9",
            "signature" => "abc123",
            "header" => %{"kid" => "key-1"}
          }
        ],
        "securityRequirements" => [
          %{"oauth2" => ["read", "write"]}
        ]
      }

      {:ok, card} = JSON.decode_agent_card(map)
      assert length(card.signatures) == 1
      [sig] = card.signatures
      assert %A2A.AgentCardSignature{} = sig
      assert sig.protected == "eyJhbGciOiJSUzI1NiJ9"
      assert sig.signature == "abc123"
      assert sig.header == %{"kid" => "key-1"}
      assert card.security_requirements == [%{"oauth2" => ["read", "write"]}]
    end
  end

  describe "AgentCard skill v1.0 fields" do
    test "decode skills with examples, input/output modes, security_requirements" do
      map = %{
        "name" => "test",
        "description" => "test agent",
        "url" => "https://example.com",
        "version" => "1.0",
        "skills" => [
          %{
            "id" => "s1",
            "name" => "Skill One",
            "description" => "Does things",
            "tags" => ["general"],
            "examples" => ["Do something", "Help me"],
            "inputModes" => ["text/plain", "application/json"],
            "outputModes" => ["text/plain"],
            "securityRequirements" => [%{"oauth2" => ["read"]}]
          }
        ]
      }

      {:ok, card} = JSON.decode_agent_card(map)
      [skill] = card.skills
      assert skill.examples == ["Do something", "Help me"]
      assert skill.input_modes == ["text/plain", "application/json"]
      assert skill.output_modes == ["text/plain"]
      assert skill.security_requirements == [%{"oauth2" => ["read"]}]
    end

    test "decode skills without v1.0 fields (backward compat)" do
      map = %{
        "name" => "test",
        "description" => "test agent",
        "url" => "https://example.com",
        "version" => "1.0",
        "skills" => [
          %{
            "id" => "s1",
            "name" => "Skill One",
            "description" => "Does things",
            "tags" => []
          }
        ]
      }

      {:ok, card} = JSON.decode_agent_card(map)
      [skill] = card.skills
      assert skill.id == "s1"
      refute Map.has_key?(skill, :examples)
      refute Map.has_key?(skill, :input_modes)
    end

    test "encode skills with v1.0 fields" do
      card = %{
        name: "test",
        description: "test agent",
        version: "1.0",
        skills: [
          %{
            id: "s1",
            name: "Skill One",
            description: "Does things",
            tags: ["general"],
            examples: ["Do something"],
            input_modes: ["text/plain"],
            output_modes: ["application/json"],
            security_requirements: [%{"key" => ["scope"]}]
          }
        ]
      }

      map = JSON.encode_agent_card(card, url: "https://example.com")
      [skill_map] = map["skills"]
      assert skill_map["examples"] == ["Do something"]
      assert skill_map["inputModes"] == ["text/plain"]
      assert skill_map["outputModes"] == ["application/json"]
      assert skill_map["securityRequirements"] == [%{"key" => ["scope"]}]
    end
  end

  describe "AgentCard capabilities extensions" do
    test "decode capabilities with extensions" do
      map = %{
        "name" => "test",
        "description" => "test agent",
        "url" => "https://example.com",
        "version" => "1.0",
        "skills" => [],
        "capabilities" => %{
          "streaming" => true,
          "extensions" => [
            %{
              "uri" => "urn:a2a:ext:test",
              "description" => "Test extension",
              "required" => true,
              "params" => %{"key" => "val"}
            }
          ]
        }
      }

      {:ok, card} = JSON.decode_agent_card(map)
      assert card.capabilities.streaming == true
      assert length(card.capabilities.extensions) == 1
      [ext] = card.capabilities.extensions
      assert %A2A.AgentExtension{} = ext
      assert ext.uri == "urn:a2a:ext:test"
      assert ext.description == "Test extension"
      assert ext.required == true
      assert ext.params == %{"key" => "val"}
    end
  end

  describe "AgentCard interface tenant" do
    test "decode interface with tenant" do
      map = %{
        "name" => "test",
        "description" => "test agent",
        "url" => "https://example.com",
        "version" => "1.0",
        "skills" => [],
        "supportedInterfaces" => [
          %{
            "url" => "https://api.example.com/a2a",
            "protocolBinding" => "JSONRPC",
            "protocolVersion" => "1.0",
            "tenant" => "tenant-1"
          }
        ]
      }

      {:ok, card} = JSON.decode_agent_card(map)
      [iface] = card.supported_interfaces
      assert iface.tenant == "tenant-1"
      assert iface.url == "https://api.example.com/a2a"
      assert iface.protocol_binding == "JSONRPC"
      assert iface.protocol_version == "1.0"
    end

    test "encode interface with tenant" do
      card = %{name: "test", description: "d", version: "1.0", skills: []}

      map =
        JSON.encode_agent_card(card,
          url: "https://example.com",
          supported_interfaces: [
            %{
              url: "https://api.example.com",
              protocol_binding: "JSONRPC",
              protocol_version: "1.0",
              tenant: "t1"
            }
          ]
        )

      [iface] = map["supportedInterfaces"]
      assert iface["tenant"] == "t1"
    end
  end

  # -------------------------------------------------------------------
  # TaskState enum — verify all v1.0 values
  # -------------------------------------------------------------------

  describe "TaskState enum values" do
    test "all v1.0 states encode correctly" do
      states = [
        :submitted,
        :working,
        :completed,
        :failed,
        :canceled,
        :input_required,
        :rejected,
        :auth_required,
        :unknown
      ]

      for state <- states do
        status = A2A.Task.Status.new(state)
        {:ok, map} = JSON.encode(status)
        assert is_binary(map["state"])
        {:ok, decoded} = JSON.decode(map, :status)
        assert decoded.state == state
      end
    end

    test "decode TASK_STATE_UNSPECIFIED" do
      # TASK_STATE_UNSPECIFIED maps to :unknown
      {:ok, state} = JSON.decode_state("TASK_STATE_UNKNOWN")
      assert state == :unknown
    end
  end
end
