defmodule A2A.JSONRPC.ErrorTest do
  use ExUnit.Case, async: true

  alias A2A.JSONRPC.Error

  doctest A2A.JSONRPC.Error

  describe "named constructors" do
    test "parse_error/0" do
      e = Error.parse_error()
      assert e.code == -32_700
      assert e.message == "Invalid JSON payload"
      assert e.data == nil
    end

    test "invalid_request/0" do
      e = Error.invalid_request()
      assert e.code == -32_600
      assert e.message == "Request payload validation error"
    end

    test "method_not_found/0" do
      e = Error.method_not_found()
      assert e.code == -32_601
      assert e.message == "Method not found"
    end

    test "invalid_params/0" do
      e = Error.invalid_params()
      assert e.code == -32_602
      assert e.message == "Invalid parameters"
    end

    test "internal_error/0" do
      e = Error.internal_error()
      assert e.code == -32_603
      assert e.message == "Internal error"
    end

    test "task_not_found/0" do
      e = Error.task_not_found()
      assert e.code == -32_001
      assert e.message == "Task not found"
    end

    test "task_not_cancelable/0" do
      e = Error.task_not_cancelable()
      assert e.code == -32_002
      assert e.message == "Task cannot be canceled"
    end

    test "push_notification_not_supported/0" do
      e = Error.push_notification_not_supported()
      assert e.code == -32_003
      assert e.message == "Push Notification is not supported"
    end

    test "unsupported_operation/0" do
      e = Error.unsupported_operation()
      assert e.code == -32_004
      assert e.message == "This operation is not supported"
    end

    test "content_type_not_supported/0" do
      e = Error.content_type_not_supported()
      assert e.code == -32_005
      assert e.message == "Incompatible content types"
    end

    test "invalid_agent_response/0" do
      e = Error.invalid_agent_response()
      assert e.code == -32_006
      assert e.message == "Invalid agent response"
    end

    test "authenticated_extended_card_not_configured/0" do
      e = Error.authenticated_extended_card_not_configured()
      assert e.code == -32_007
      assert e.message == "Authenticated Extended Card is not configured"
    end

    test "extension_support_required/0" do
      e = Error.extension_support_required()
      assert e.code == -32_008
      assert e.message == "Extension support is required"
      assert e.data == nil
    end

    test "version_not_supported/0" do
      e = Error.version_not_supported()
      assert e.code == -32_009
      assert e.message == "Version not supported"
      assert e.data == nil
    end

    test "constructors accept optional data" do
      e = Error.parse_error("unexpected token")
      assert e.data == "unexpected token"
    end
  end

  describe "to_map/1" do
    test "an A2A code carries ErrorInfo even with no data" do
      map = Error.to_map(Error.task_not_found())

      assert map == %{
               "code" => -32_001,
               "message" => "Task not found",
               "data" => [
                 %{
                   "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
                   "domain" => "a2a-protocol.org",
                   "reason" => "TASK_NOT_FOUND"
                 }
               ]
             }
    end

    test "an A2A code preserves free-form data under ErrorInfo metadata" do
      map = Error.to_map(Error.version_not_supported("9.9"))
      [info] = map["data"]

      assert info["reason"] == "VERSION_NOT_SUPPORTED"
      assert info["metadata"] == %{"detail" => "9.9"}
    end

    test "non-binary data is inspected into metadata" do
      map = Error.to_map(Error.task_not_cancelable({:bad, :state}))
      [info] = map["data"]

      assert info["metadata"] == %{"detail" => "{:bad, :state}"}
    end

    test "a standard JSON-RPC code keeps free-form data" do
      map = Error.to_map(Error.internal_error("boom"))

      assert map == %{
               "code" => -32_603,
               "message" => "Internal error",
               "data" => "boom"
             }
    end

    test "a standard JSON-RPC code omits data when nil" do
      map = Error.to_map(Error.parse_error())

      assert map == %{"code" => -32_700, "message" => "Invalid JSON payload"}
      refute Map.has_key?(map, "data")
    end

    test "every A2A code emits its spec reason" do
      # Keyed by code, not by constructor name — -32007's reason drops the
      # "authenticated" prefix its constructor carries.
      expected = [
        {Error.task_not_found(), "TASK_NOT_FOUND"},
        {Error.task_not_cancelable(), "TASK_NOT_CANCELABLE"},
        {Error.push_notification_not_supported(), "PUSH_NOTIFICATION_NOT_SUPPORTED"},
        {Error.unsupported_operation(), "UNSUPPORTED_OPERATION"},
        {Error.content_type_not_supported(), "CONTENT_TYPE_NOT_SUPPORTED"},
        {Error.invalid_agent_response(), "INVALID_AGENT_RESPONSE"},
        {Error.authenticated_extended_card_not_configured(),
         "EXTENDED_AGENT_CARD_NOT_CONFIGURED"},
        {Error.extension_support_required(), "EXTENSION_SUPPORT_REQUIRED"},
        {Error.version_not_supported(), "VERSION_NOT_SUPPORTED"}
      ]

      for {error, reason} <- expected do
        [info] = Error.to_map(error)["data"]
        assert info["@type"] == "type.googleapis.com/google.rpc.ErrorInfo"
        assert info["domain"] == "a2a-protocol.org"
        assert info["reason"] == reason, "wrong reason for #{error.code}"
      end
    end

    test "is idempotent on an already-wrapped error" do
      once = Error.to_map(Error.task_not_found())
      twice = Error.to_map(%Error{code: -32_001, message: "Task not found", data: once["data"]})

      assert twice == once
    end
  end
end
