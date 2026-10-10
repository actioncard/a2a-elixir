defmodule A2A.IDTest do
  use ExUnit.Case, async: true

  alias A2A.ID

  describe "generate/1" do
    test "returns a string with the given prefix" do
      id = ID.generate("tsk")
      assert String.starts_with?(id, "tsk-")
    end

    test "suffix is 12 alphanumeric characters" do
      id = ID.generate("msg")
      [_prefix, suffix] = String.split(id, "-", parts: 2)
      assert String.length(suffix) == 12
      assert Regex.match?(~r/^[0-9a-zA-Z]+$/, suffix)
    end

    test "generates unique IDs" do
      ids = for _ <- 1..100, do: ID.generate("x")
      assert length(Enum.uniq(ids)) == 100
    end

    test "works with different prefixes" do
      for prefix <- ["tsk", "msg", "art", "ctx", ""] do
        id = ID.generate(prefix)
        assert String.starts_with?(id, "#{prefix}-")
      end
    end
  end
end
