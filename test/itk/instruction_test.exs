defmodule A2A.Test.ITK.InstructionTest do
  use ExUnit.Case, async: true

  alias A2A.Test.ITK.Instruction

  describe "round-trip encode/decode" do
    test "return_response" do
      inst = {:return_response, "traversal-completed:jsonrpc"}
      assert {:ok, ^inst} = Instruction.decode(Instruction.encode(inst))
    end

    test "steps with concat generator" do
      inst =
        {:steps,
         [
           {:return_response, "[a -> b (jsonrpc)]"},
           {:return_response, "tail"}
         ], 1}

      assert {:ok, decoded} = Instruction.decode(Instruction.encode(inst))
      assert decoded == inst
    end

    test "steps with unspecified generator (0) omitted on wire" do
      inst = {:steps, [{:return_response, "x"}], 0}
      assert {:ok, ^inst} = Instruction.decode(Instruction.encode(inst))
    end

    test "call_agent with nested instruction" do
      inst =
        {:call_agent,
         %{
           transport: "jsonrpc",
           agent_card_uri: "http://127.0.0.1:1234/jsonrpc",
           instruction: {:return_response, "leaf"},
           streaming: true
         }}

      assert {:ok, decoded} = Instruction.decode(Instruction.encode(inst))
      assert decoded == inst
    end

    test "deeply nested A->B->A traversal shape" do
      leaf = {:return_response, "traversal-completed:jsonrpc"}

      hop_b =
        {:steps,
         [
           {:return_response, "[B -> A (jsonrpc)]"},
           {:call_agent,
            %{
              transport: "jsonrpc",
              agent_card_uri: "http://127.0.0.1:2/jsonrpc",
              instruction: leaf,
              streaming: false
            }}
         ], 1}

      root =
        {:steps,
         [
           {:return_response, "[A -> B (jsonrpc)]"},
           {:call_agent,
            %{
              transport: "jsonrpc",
              agent_card_uri: "http://127.0.0.1:1/jsonrpc",
              instruction: hop_b,
              streaming: false
            }}
         ], 1}

      assert {:ok, decoded} = Instruction.decode(Instruction.encode(root))
      assert decoded == root
    end
  end

  describe "decodes Python-generated fixtures" do
    @fixture_dir Path.join([__DIR__, "fixtures"])

    test "decodes captured python_v03 instruction.bin fixtures, if present" do
      case File.ls(@fixture_dir) do
        {:ok, files} ->
          bins = Enum.filter(files, &String.ends_with?(&1, ".bin"))

          if bins == [] do
            # No fixtures captured in this environment; skip silently.
            assert true
          else
            for f <- bins do
              raw = File.read!(Path.join(@fixture_dir, f))
              assert {:ok, _inst} = Instruction.decode(raw)
            end

            assert_fixture("return_response.bin", {:return_response, "traversal-completed:jsonrpc"})

            assert_fixture(
              "steps_concat.bin",
              {:steps,
               [
                 {:return_response, "[a -> b (jsonrpc)]"},
                 {:return_response, "traversal-completed:jsonrpc"}
               ], 1}
            )

            assert_fixture(
              "call_agent_hop.bin",
              {:steps,
               [
                 {:return_response, "[A -> B (jsonrpc)]"},
                 {:call_agent,
                  %{
                    transport: "jsonrpc",
                    agent_card_uri: "http://127.0.0.1:1234/jsonrpc",
                    instruction: {:return_response, "traversal-completed:jsonrpc"},
                    streaming: false
                  }}
               ], 1}
            )
          end

        {:error, _} ->
          assert true
      end
    end

    defp assert_fixture(name, expected) do
      raw = File.read!(Path.join(@fixture_dir, name))
      assert {:ok, ^expected} = Instruction.decode(raw)
    end
  end
end
