defmodule A2ATest do
  use ExUnit.Case, async: true

  doctest A2A

  test "module is loaded" do
    assert Code.ensure_loaded?(A2A)
  end
end
