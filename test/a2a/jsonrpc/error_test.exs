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
    test "without data" do
      map = Error.to_map(Error.task_not_found())
      assert map == %{"code" => -32_001, "message" => "Task not found"}
      refute Map.has_key?(map, "data")
    end

    test "with data" do
      map = Error.to_map(Error.internal_error("boom"))

      assert map == %{
               "code" => -32_603,
               "message" => "Internal error",
               "data" => "boom"
             }
    end
  end
end
