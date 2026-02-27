defmodule A2A.JSONRPC.ResponseTest do
  use ExUnit.Case, async: true

  alias A2A.JSONRPC.{Error, Response}

  describe "success/2" do
    test "builds success envelope" do
      result = %{"kind" => "task", "id" => "tsk-1", "status" => %{"state" => "completed"}}
      response = Response.success(1, result)

      assert response == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "result" => result
             }
    end

    test "works with string id" do
      response = Response.success("abc", %{})
      assert response["id"] == "abc"
    end

    test "works with nil id" do
      response = Response.success(nil, %{})
      assert response["id"] == nil
    end
  end

  describe "error/2" do
    test "builds error envelope" do
      error = Error.task_not_found()
      response = Response.error(1, error)

      assert response == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "error" => %{"code" => -32_001, "message" => "Task not found"}
             }
    end

    test "includes data when present" do
      error = Error.internal_error("details")
      response = Response.error(1, error)

      assert response["error"]["data"] == "details"
    end
  end
end
