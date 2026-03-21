defmodule A2A.PushNotificationConfigTest do
  use ExUnit.Case, async: true

  alias A2A.PushNotificationConfig
  alias A2A.AuthenticationInfo

  describe "PushNotificationConfig struct" do
    test "creates with all fields" do
      config = %PushNotificationConfig{
        id: "cfg-123",
        task_id: "tsk-abc",
        url: "https://example.com/webhook",
        token: "my-token",
        authentication: %AuthenticationInfo{scheme: "Bearer", credentials: "secret"}
      }

      assert config.id == "cfg-123"
      assert config.url == "https://example.com/webhook"
      assert config.authentication.scheme == "Bearer"
    end

    test "creates with minimal fields" do
      config = %PushNotificationConfig{url: "https://example.com/hook"}
      assert config.url == "https://example.com/hook"
      assert config.id == nil
    end
  end

  describe "AuthenticationInfo struct" do
    test "requires scheme" do
      auth = %AuthenticationInfo{scheme: "Bearer", credentials: "tok"}
      assert auth.scheme == "Bearer"
    end

    test "credentials is optional" do
      auth = %AuthenticationInfo{scheme: "Basic"}
      assert auth.credentials == nil
    end
  end
end
