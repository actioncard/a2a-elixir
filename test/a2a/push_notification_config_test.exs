defmodule A2A.PushNotificationConfigTest do
  use ExUnit.Case, async: true

  alias A2A.JSON
  alias A2A.PushNotificationConfig

  describe "encode/1" do
    test "emits camelCase keys" do
      config = %PushNotificationConfig{
        id: "pcfg-1",
        task_id: "tsk-1",
        url: "https://example.com/hook",
        token: "tok",
        authentication: %{scheme: "Bearer", credentials: "s3cret"}
      }

      assert {:ok, encoded} = JSON.encode(config)

      assert encoded == %{
               "id" => "pcfg-1",
               "taskId" => "tsk-1",
               "url" => "https://example.com/hook",
               "token" => "tok",
               "authentication" => %{"scheme" => "Bearer", "credentials" => "s3cret"}
             }
    end

    test "omits absent optional fields" do
      assert {:ok, encoded} =
               JSON.encode(%PushNotificationConfig{url: "https://example.com/hook"})

      assert encoded == %{"url" => "https://example.com/hook"}
    end

    test "omits authentication carrying no scheme or credentials" do
      config = %PushNotificationConfig{url: "https://example.com/hook", authentication: %{}}

      assert {:ok, encoded} = JSON.encode(config)
      refute Map.has_key?(encoded, "authentication")
    end
  end

  describe "decode/2" do
    test "reads the camelCase taskId the spec defines" do
      raw = %{"id" => "pcfg-1", "taskId" => "tsk-1", "url" => "https://example.com/hook"}

      assert {:ok, config} = JSON.decode(raw, :push_notification_config)
      assert config.task_id == "tsk-1"
      assert config.id == "pcfg-1"
    end

    test "reads the snake_case task_id the TCK sends" do
      raw = %{"task_id" => "tsk-1", "url" => "https://example.com/hook"}

      assert {:ok, config} = JSON.decode(raw, :push_notification_config)
      assert config.task_id == "tsk-1"
    end

    test "reads a singular authentication scheme" do
      raw = %{
        "url" => "https://example.com/hook",
        "authentication" => %{"scheme" => "Bearer", "credentials" => "s3cret"}
      }

      assert {:ok, config} = JSON.decode(raw, :push_notification_config)
      assert config.authentication == %{scheme: "Bearer", credentials: "s3cret"}
    end

    test "normalizes the spec's plural schemes array to a single scheme" do
      raw = %{
        "url" => "https://example.com/hook",
        "authentication" => %{"schemes" => ["Bearer", "ApiKey"], "credentials" => "s3cret"}
      }

      assert {:ok, config} = JSON.decode(raw, :push_notification_config)
      assert config.authentication == %{scheme: "Bearer", credentials: "s3cret"}
    end

    test "treats an empty authentication object as absent" do
      raw = %{"url" => "https://example.com/hook", "authentication" => %{}}

      assert {:ok, config} = JSON.decode(raw, :push_notification_config)
      assert config.authentication == nil
    end

    test "requires a url" do
      assert {:error, {:missing_field, "url"}} =
               JSON.decode(%{"task_id" => "tsk-1"}, :push_notification_config)
    end
  end

  test "round-trips through encode and decode" do
    config = %PushNotificationConfig{
      id: "pcfg-1",
      task_id: "tsk-1",
      url: "https://example.com/hook",
      token: "tok",
      authentication: %{scheme: "Bearer", credentials: "s3cret"}
    }

    assert {:ok, encoded} = JSON.encode(config)
    assert {:ok, ^config} = JSON.decode(encoded, :push_notification_config)
  end
end
