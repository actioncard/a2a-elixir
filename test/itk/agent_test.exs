defmodule A2A.Test.ITK.AgentTest do
  use ExUnit.Case, async: true

  alias A2A.Test.ITK.Agent
  alias A2A.Test.ITK.Instruction

  describe "interpret/2 (pure interpretation, downstream stubbed)" do
    test "return_response yields its text" do
      assert Agent.interpret({:return_response, "hello"}) == "hello"
    end

    test "steps concatenates fragments with newlines, skipping empties" do
      inst =
        {:steps,
         [
           {:return_response, "[a -> b (jsonrpc)]"},
           {:return_response, ""},
           {:return_response, "traversal-completed:jsonrpc"}
         ], 1}

      assert Agent.interpret(inst) ==
               "[a -> b (jsonrpc)]\ntraversal-completed:jsonrpc"
    end

    test "call_agent invokes the supplied call_fun and uses its result" do
      stub = fn %{agent_card_uri: uri} -> "downstream:#{uri}" end

      inst =
        {:call_agent,
         %{
           transport: "jsonrpc",
           agent_card_uri: "http://127.0.0.1:1/jsonrpc",
           instruction: {:return_response, "leaf"},
           streaming: false
         }}

      assert Agent.interpret(inst, stub) == "downstream:http://127.0.0.1:1/jsonrpc"
    end

    test "nested A->B->A traversal shape concatenates trace + downstream text" do
      # B's local fragment + B's downstream (the leaf) — stub returns leaf text.
      stub = fn %{instruction: leaf} -> Agent.interpret(leaf, fn _ -> "" end) end

      root =
        {:steps,
         [
           {:return_response, "[A -> B (jsonrpc)]"},
           {:call_agent,
            %{
              transport: "jsonrpc",
              agent_card_uri: "http://127.0.0.1:1/jsonrpc",
              instruction: {:return_response, "traversal-completed:jsonrpc"},
              streaming: false
            }}
         ], 1}

      assert Agent.interpret(root, stub) ==
               "[A -> B (jsonrpc)]\ntraversal-completed:jsonrpc"
    end
  end

  describe "call_downstream/1 transport guard" do
    test "non-jsonrpc transport returns a visible error fragment" do
      result =
        Agent.call_downstream(%{
          transport: "grpc",
          agent_card_uri: "http://127.0.0.1:1/grpc",
          instruction: {:return_response, "x"},
          streaming: false
        })

      assert result =~ "unsupported transport"
      assert result =~ "grpc"
    end
  end

  describe "handle_send/3 (end-to-end over a decoded FilePart, no network)" do
    test "decodes a return_response instruction and completes with status.message" do
      inst = {:return_response, "traversal-completed:jsonrpc"}
      message = build_instruction_message(inst)

      assert {:ok, task} = Agent.handle_send(message, %{}, %{})
      assert task.status.state == :completed
      assert A2A.Message.text(task.status.message) == "traversal-completed:jsonrpc"
    end

    test "errors when no instruction FilePart is present" do
      message = A2A.Message.new_user("just text, no proto")
      assert {:error, error} = Agent.handle_send(message, %{}, %{})
      assert error.code == -32602
    end
  end

  defp build_instruction_message(inst) do
    bytes = Instruction.encode(inst)

    file =
      A2A.FileContent.from_bytes(bytes,
        name: "instruction.bin",
        mime_type: "application/x-protobuf"
      )

    A2A.Message.new_user([A2A.Part.File.new(file)])
  end
end
