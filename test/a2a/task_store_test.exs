defmodule A2A.TaskStoreTest do
  use ExUnit.Case, async: true

  # The TaskStore module defines a behaviour only — there is nothing to call
  # directly. This test verifies that the behaviour callbacks are properly
  # declared and that A2A.TaskStore.ETS implements them.

  describe "behaviour callbacks" do
    test "required callbacks are declared" do
      callbacks = A2A.TaskStore.behaviour_info(:callbacks)
      assert {:get, 2} in callbacks
      assert {:put, 2} in callbacks
      assert {:delete, 2} in callbacks
      assert {:list, 2} in callbacks
    end

    test "list_all/2 is an optional callback" do
      optional = A2A.TaskStore.behaviour_info(:optional_callbacks)
      assert {:list_all, 2} in optional
    end
  end

  describe "ETS implementation contract" do
    test "implements all required callbacks" do
      behaviours = A2A.TaskStore.ETS.__info__(:attributes) |> Keyword.get(:behaviour, [])
      assert A2A.TaskStore in behaviours
    end
  end
end
