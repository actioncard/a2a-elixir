defmodule A2A.JSON.PushConfigTest do
  use ExUnit.Case, async: true

  alias A2A.PushNotificationConfig
  alias A2A.AuthenticationInfo

  describe "encode push notification config" do
    test "encodes full config" do
      config = %PushNotificationConfig{
        id: "cfg-1",
        task_id: "tsk-abc",
        url: "https://example.com/hook",
        token: "my-token",
        authentication: %AuthenticationInfo{scheme: "Bearer", credentials: "secret"}
      }

      {:ok, map} = A2A.JSON.encode(config)
      assert map["id"] == "cfg-1"
      assert map["taskId"] == "tsk-abc"
      assert map["authentication"]["scheme"] == "Bearer"
    end

    test "encodes minimal config" do
      {:ok, map} = A2A.JSON.encode(%PushNotificationConfig{url: "https://x.com/h"})
      assert map["url"] == "https://x.com/h"
      refute Map.has_key?(map, "id")
    end
  end

  describe "decode push notification config" do
    test "decodes full config" do
      map = %{
        "id" => "cfg-1",
        "taskId" => "tsk-abc",
        "url" => "https://example.com/hook",
        "token" => "tok",
        "authentication" => %{"scheme" => "Bearer", "credentials" => "secret"}
      }

      {:ok, config} = A2A.JSON.decode(map, :push_notification_config)
      assert config.id == "cfg-1"
      assert config.authentication.scheme == "Bearer"
    end

    test "round-trips through encode/decode" do
      config = %PushNotificationConfig{
        id: "cfg-rt",
        task_id: "tsk-rt",
        url: "https://example.com/hook",
        token: "tok",
        authentication: %AuthenticationInfo{scheme: "Bearer", credentials: "cred"}
      }

      {:ok, encoded} = A2A.JSON.encode(config)
      {:ok, decoded} = A2A.JSON.decode(encoded, :push_notification_config)
      assert decoded.id == config.id
      assert decoded.authentication.scheme == config.authentication.scheme
    end
  end

  describe "encode AuthenticationInfo" do
    test "encodes full auth info" do
      {:ok, map} = A2A.JSON.encode(%AuthenticationInfo{scheme: "Bearer", credentials: "tok"})
      assert map["scheme"] == "Bearer"
    end

    test "encodes auth without credentials" do
      {:ok, map} = A2A.JSON.encode(%AuthenticationInfo{scheme: "Basic"})
      refute Map.has_key?(map, "credentials")
    end
  end
end
