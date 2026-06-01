defmodule A2A.ExtensionTest do
  use ExUnit.Case, async: true

  alias A2A.{AgentExtension, Extension}
  alias A2A.Test.Extensions.{DataOnly, Passport, SkipMe, Timestamp}

  describe "compile/1" do
    test "accepts plain module and {module, opts}" do
      [{Timestamp, _state, decl1}, {Passport, "acme", decl2}] =
        Extension.compile([Timestamp, {Passport, issuer: "acme"}])

      assert decl1.uri == "https://example.test/ext/timestamp"
      assert decl2.uri == "https://example.test/ext/passport"
      assert decl2.required == true
    end

    test "calls init/1 with the provided opts when defined" do
      [{_mod, state, _decl}] = Extension.compile([{Passport, issuer: "issuer-a"}])
      assert state == "issuer-a"
    end

    test "defaults state to nil for modules without init/1" do
      [{Timestamp, state, _decl}] = Extension.compile([Timestamp])
      assert state == nil
    end
  end

  describe "parse_header/1" do
    test "handles nil, string, and list-of-strings forms" do
      assert Extension.parse_header(nil) == []
      assert Extension.parse_header("a, b , c") == ["a", "b", "c"]
      assert Extension.parse_header(["a, b", "c"]) == ["a", "b", "c"]
      assert Extension.parse_header([""]) == []
    end
  end

  describe "validate_required/2" do
    test ":ok when no required extensions" do
      compiled = Extension.compile([Timestamp])
      assert :ok == Extension.validate_required(compiled, [])
    end

    test ":ok when required URI is in requested set" do
      compiled = Extension.compile([Passport])

      assert :ok ==
               Extension.validate_required(
                 compiled,
                 ["https://example.test/ext/passport"]
               )
    end

    test "returns missing URIs when required absent" do
      compiled = Extension.compile([Passport, Timestamp])

      assert {:error, ["https://example.test/ext/passport"]} =
               Extension.validate_required(compiled, [])
    end
  end

  describe "activate/3" do
    test "activates only extensions whose URI is in the requested set, in order" do
      compiled = Extension.compile([Timestamp, Passport])

      {:ok, activations, uris} =
        Extension.activate(
          compiled,
          [
            "https://example.test/ext/passport",
            "https://example.test/ext/timestamp"
          ],
          %{}
        )

      assert [{Timestamp, _, _}, {Passport, %{issuer: "default"}, _}] = activations

      assert uris == [
               "https://example.test/ext/timestamp",
               "https://example.test/ext/passport"
             ]
    end

    test "omits extensions whose activate/3 returns :skip" do
      compiled = Extension.compile([SkipMe, Timestamp])

      {:ok, activations, uris} =
        Extension.activate(
          compiled,
          [
            "https://example.test/ext/skip",
            "https://example.test/ext/timestamp"
          ],
          %{}
        )

      assert Enum.map(activations, fn {m, _, _} -> m end) == [Timestamp]
      assert uris == ["https://example.test/ext/timestamp"]
    end

    test "defaults to {:ok, nil} when activate/3 is not defined" do
      compiled = Extension.compile([DataOnly])

      {:ok, [{DataOnly, nil, _}], ["https://example.test/ext/data-only"]} =
        Extension.activate(
          compiled,
          ["https://example.test/ext/data-only"],
          %{}
        )
    end

    test "propagates {:error, jsonrpc_error} from activate/3" do
      defmodule ErroringExt do
        @moduledoc false
        @behaviour A2A.Extension
        def declaration(_), do: %A2A.AgentExtension{uri: "https://example.test/ext/err"}
        def activate(_, _, _), do: {:error, A2A.JSONRPC.Error.invalid_request("nope")}
      end

      compiled = Extension.compile([ErroringExt])

      assert {:error, %A2A.JSONRPC.Error{code: -32_600, data: "nope"}} =
               Extension.activate(
                 compiled,
                 ["https://example.test/ext/err"],
                 %{}
               )
    end
  end

  describe "run_request/3 and run_response/3" do
    test "chains handle_request mutations in order" do
      compiled = Extension.compile([Timestamp])

      {:ok, activations, _} =
        Extension.activate(
          compiled,
          ["https://example.test/ext/timestamp"],
          %{}
        )

      message = A2A.Message.new_user([A2A.Part.Text.new("hi")])

      {:ok, message2, _params, _acts} = Extension.run_request(activations, message, %{})

      assert %{"https://example.test/ext/timestamp" => %{seen_at: 1_700_000_000_000}} =
               message2.metadata
    end

    test "chains handle_response mutations in order" do
      compiled = Extension.compile([Timestamp])

      {:ok, activations, _} =
        Extension.activate(
          compiled,
          ["https://example.test/ext/timestamp"],
          %{}
        )

      task = A2A.Task.new()

      {:ok, task2, _} = Extension.run_response(activations, task, %{})

      assert %{"https://example.test/ext/timestamp" => %{finished_at: 1_700_000_000_000}} =
               task2.metadata
    end

    test "skips hooks for extensions that don't define them" do
      compiled = Extension.compile([DataOnly])

      {:ok, activations, _} =
        Extension.activate(
          compiled,
          ["https://example.test/ext/data-only"],
          %{}
        )

      message = A2A.Message.new_user([A2A.Part.Text.new("hi")])
      task = A2A.Task.new()

      assert {:ok, ^message, %{}, ^activations} = Extension.run_request(activations, message, %{})
      assert {:ok, ^task, ^activations} = Extension.run_response(activations, task, %{})
    end
  end

  describe "helpers" do
    test "to_context_map/1 keys activations by URI" do
      activations = [
        {Timestamp, %{started_at: 1}, "https://example.test/ext/timestamp"},
        {Passport, %{issuer: "x"}, "https://example.test/ext/passport"}
      ]

      assert Extension.to_context_map(activations) == %{
               "https://example.test/ext/timestamp" => %{started_at: 1},
               "https://example.test/ext/passport" => %{issuer: "x"}
             }
    end

    test "fetch/2 looks up activation by module" do
      ctx = %{
        extensions: %{
          "https://example.test/ext/timestamp" => %{started_at: 1}
        }
      }

      assert Extension.fetch(ctx, Timestamp) == {:ok, %{started_at: 1}}
      assert Extension.fetch(ctx, Passport) == :error
      assert Extension.fetch(%{}, Timestamp) == :error
    end

    test "activated?/2 is boolean sugar over fetch" do
      ctx = %{
        extensions: %{"https://example.test/ext/timestamp" => nil}
      }

      assert Extension.activated?(ctx, Timestamp)
      refute Extension.activated?(ctx, Passport)
    end

    test "put_metadata/3 namespaces a value under the extension URI" do
      message = A2A.Message.new_user([A2A.Part.Text.new("hi")])
      message = Extension.put_metadata(message, Timestamp, %{seen: true})

      assert message.metadata == %{
               "https://example.test/ext/timestamp" => %{seen: true}
             }

      task = A2A.Task.new()
      task = Extension.put_metadata(task, Timestamp, %{done: true})

      assert task.metadata == %{
               "https://example.test/ext/timestamp" => %{done: true}
             }
    end
  end

  describe "declarations/1 and required_uris/1" do
    test "returns declarations in input order" do
      compiled = Extension.compile([Timestamp, Passport, DataOnly])

      assert Enum.map(Extension.declarations(compiled), & &1.uri) == [
               "https://example.test/ext/timestamp",
               "https://example.test/ext/passport",
               "https://example.test/ext/data-only"
             ]

      assert Extension.required_uris(compiled) == ["https://example.test/ext/passport"]

      assert Extension.declared_uris(compiled) == [
               "https://example.test/ext/timestamp",
               "https://example.test/ext/passport",
               "https://example.test/ext/data-only"
             ]
    end

    test "embeds AgentExtension structs" do
      compiled = Extension.compile([DataOnly])

      assert [%AgentExtension{uri: "https://example.test/ext/data-only", params: %{}}] =
               Extension.declarations(compiled)
    end
  end
end
