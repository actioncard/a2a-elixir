defmodule A2A.AgentExtensionTest do
  use ExUnit.Case, async: true

  alias A2A.AgentExtension

  test "defaults required to false and other fields to nil" do
    ext = %AgentExtension{uri: "https://example.com/ext/a"}
    assert ext.uri == "https://example.com/ext/a"
    assert ext.required == false
    assert ext.description == nil
    assert ext.params == nil
  end

  test "accepts all fields" do
    ext = %AgentExtension{
      uri: "https://example.com/ext/b",
      description: "Test",
      required: true,
      params: %{"version" => "1.0"}
    }

    assert ext.required == true
    assert ext.params == %{"version" => "1.0"}
  end

  test "enforces :uri" do
    assert_raise ArgumentError, fn ->
      struct!(AgentExtension, %{description: "no uri"})
    end
  end
end
