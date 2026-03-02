defmodule A2A.JSONRPC.RequestTest do
  use ExUnit.Case, async: true

  alias A2A.JSONRPC.{Error, Request}

  describe "parse/1" do
    test "valid request with all fields" do
      raw = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "message/send",
        "params" => %{"message" => %{"role" => "user", "parts" => []}}
      }

      assert {:ok, %Request{} = req} = Request.parse(raw)
      assert req.jsonrpc == "2.0"
      assert req.id == 1
      assert req.method == "message/send"
      assert req.params == %{"message" => %{"role" => "user", "parts" => []}}
    end

    test "valid request with string id" do
      raw = %{"jsonrpc" => "2.0", "id" => "abc", "method" => "tasks/get", "params" => %{}}
      assert {:ok, %Request{id: "abc"}} = Request.parse(raw)
    end

    test "valid request without id (notification)" do
      raw = %{"jsonrpc" => "2.0", "method" => "tasks/get"}
      assert {:ok, %Request{id: nil}} = Request.parse(raw)
    end

    test "defaults params to empty map" do
      raw = %{"jsonrpc" => "2.0", "method" => "tasks/get"}
      assert {:ok, %Request{params: %{}}} = Request.parse(raw)
    end

    test "rejects missing jsonrpc" do
      raw = %{"method" => "tasks/get"}
      assert {:error, %Error{code: -32_600}} = Request.parse(raw)
    end

    test "rejects wrong jsonrpc version" do
      raw = %{"jsonrpc" => "1.0", "method" => "tasks/get"}
      assert {:error, %Error{code: -32_600}} = Request.parse(raw)
    end

    test "rejects missing method" do
      raw = %{"jsonrpc" => "2.0"}
      assert {:error, %Error{code: -32_600}} = Request.parse(raw)
    end

    test "rejects non-string method" do
      raw = %{"jsonrpc" => "2.0", "method" => 42}
      assert {:error, %Error{code: -32_600}} = Request.parse(raw)
    end

    test "rejects invalid id type" do
      raw = %{"jsonrpc" => "2.0", "method" => "tasks/get", "id" => [1]}
      assert {:error, %Error{code: -32_600}} = Request.parse(raw)
    end

    test "rejects non-map body" do
      assert {:error, %Error{code: -32_600}} = Request.parse("not a map")
    end
  end

  describe "validate_params/1" do
    test "message/send requires message map" do
      req = %Request{jsonrpc: "2.0", method: "message/send", params: %{"message" => %{}}}
      assert :ok = Request.validate_params(req)
    end

    test "message/send rejects missing message" do
      req = %Request{jsonrpc: "2.0", method: "message/send", params: %{}}
      assert {:error, %Error{code: -32_602}} = Request.validate_params(req)
    end

    test "message/stream requires message map" do
      req = %Request{jsonrpc: "2.0", method: "message/stream", params: %{"message" => %{}}}
      assert :ok = Request.validate_params(req)
    end

    test "tasks/get requires string id" do
      req = %Request{jsonrpc: "2.0", method: "tasks/get", params: %{"id" => "tsk-1"}}
      assert :ok = Request.validate_params(req)
    end

    test "tasks/get rejects missing id" do
      req = %Request{jsonrpc: "2.0", method: "tasks/get", params: %{}}
      assert {:error, %Error{code: -32_602}} = Request.validate_params(req)
    end

    test "tasks/cancel requires string id" do
      req = %Request{jsonrpc: "2.0", method: "tasks/cancel", params: %{"id" => "tsk-1"}}
      assert :ok = Request.validate_params(req)
    end

    test "tasks/resubscribe requires string id" do
      req = %Request{
        jsonrpc: "2.0",
        method: "tasks/resubscribe",
        params: %{"id" => "tsk-1"}
      }

      assert :ok = Request.validate_params(req)
    end

    test "unknown method passes without validation" do
      req = %Request{jsonrpc: "2.0", method: "custom/thing", params: %{}}
      assert :ok = Request.validate_params(req)
    end

    # -- tasks/list validation -------------------------------------------------

    test "tasks/list accepts valid params" do
      req = %Request{
        jsonrpc: "2.0",
        method: "tasks/list",
        params: %{
          "pageSize" => 10,
          "status" => "TASK_STATE_WORKING",
          "historyLength" => 5,
          "statusTimestampAfter" => "2025-01-01T00:00:00Z"
        }
      }

      assert :ok = Request.validate_params(req)
    end

    test "tasks/list accepts empty params" do
      req = %Request{jsonrpc: "2.0", method: "tasks/list", params: %{}}
      assert :ok = Request.validate_params(req)
    end

    test "tasks/list rejects invalid pageSize" do
      req = %Request{
        jsonrpc: "2.0",
        method: "tasks/list",
        params: %{"pageSize" => 0}
      }

      assert {:error, %Error{code: -32_602}} = Request.validate_params(req)
    end

    test "tasks/list rejects invalid status" do
      req = %Request{
        jsonrpc: "2.0",
        method: "tasks/list",
        params: %{"status" => "INVALID_STATUS"}
      }

      assert {:error, %Error{code: -32_602}} = Request.validate_params(req)
    end

    test "tasks/list rejects non-string status" do
      req = %Request{
        jsonrpc: "2.0",
        method: "tasks/list",
        params: %{"status" => 123}
      }

      assert {:error, %Error{code: -32_602}} = Request.validate_params(req)
    end

    test "tasks/list rejects negative historyLength" do
      req = %Request{
        jsonrpc: "2.0",
        method: "tasks/list",
        params: %{"historyLength" => -1}
      }

      assert {:error, %Error{code: -32_602}} = Request.validate_params(req)
    end

    test "tasks/list rejects non-integer historyLength" do
      req = %Request{
        jsonrpc: "2.0",
        method: "tasks/list",
        params: %{"historyLength" => "five"}
      }

      assert {:error, %Error{code: -32_602}} = Request.validate_params(req)
    end

    test "tasks/list rejects invalid timestamp" do
      req = %Request{
        jsonrpc: "2.0",
        method: "tasks/list",
        params: %{"statusTimestampAfter" => "not-a-timestamp"}
      }

      assert {:error, %Error{code: -32_602}} = Request.validate_params(req)
    end

    test "tasks/list rejects non-string timestamp" do
      req = %Request{
        jsonrpc: "2.0",
        method: "tasks/list",
        params: %{"statusTimestampAfter" => 12345}
      }

      assert {:error, %Error{code: -32_602}} = Request.validate_params(req)
    end

    test "tasks/list accepts all valid status values" do
      statuses = ~w(
        TASK_STATE_SUBMITTED TASK_STATE_WORKING TASK_STATE_INPUT_REQUIRED
        TASK_STATE_COMPLETED TASK_STATE_CANCELED TASK_STATE_FAILED
        TASK_STATE_REJECTED TASK_STATE_AUTH_REQUIRED TASK_STATE_UNKNOWN
      )

      for status <- statuses do
        req = %Request{
          jsonrpc: "2.0",
          method: "tasks/list",
          params: %{"status" => status}
        }

        assert :ok = Request.validate_params(req),
               "expected #{status} to be valid"
      end
    end
  end
end
