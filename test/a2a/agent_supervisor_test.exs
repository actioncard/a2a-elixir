defmodule A2A.AgentSupervisorTest do
  use ExUnit.Case, async: false

  alias A2A.AgentSupervisor

  setup do
    name = :"sup_#{System.unique_integer([:positive])}"
    registry = :"reg_#{System.unique_integer([:positive])}"

    %{sup_name: name, registry: registry}
  end

  describe "start_link/1" do
    test "starts registry and agents", %{sup_name: name, registry: registry} do
      sup =
        start_supervised!(
          {AgentSupervisor, name: name, registry: registry, agents: [A2A.Test.EchoAgent]}
        )

      assert Process.alive?(sup)
      assert Process.whereis(registry) != nil
      assert Process.whereis(A2A.Test.EchoAgent) != nil
    end

    test "agents are callable via A2A.call/3", %{sup_name: name, registry: registry} do
      start_supervised!(
        {AgentSupervisor, name: name, registry: registry, agents: [A2A.Test.EchoAgent]}
      )

      {:ok, task} = A2A.call(A2A.Test.EchoAgent, "hello")
      assert task.status.state == :completed
    end

    test "registry contains all started agents",
         %{sup_name: name, registry: registry} do
      start_supervised!(
        {AgentSupervisor, name: name, registry: registry, agents: [A2A.Test.EchoAgent]}
      )

      assert {:ok, card} = A2A.Registry.get(registry, A2A.Test.EchoAgent)
      assert card.name == "echo"
    end

    test "find_by_skill works end-to-end",
         %{sup_name: name, registry: registry} do
      start_supervised!(
        {AgentSupervisor, name: name, registry: registry, agents: [A2A.Test.EchoAgent]}
      )

      assert [A2A.Test.EchoAgent] = A2A.Registry.find_by_skill(registry, "test")
    end

    test "supports per-agent opts via {mod, opts} tuples",
         %{sup_name: name, registry: registry} do
      store_name = :"store_#{System.unique_integer([:positive])}"
      start_supervised!({A2A.TaskStore.ETS, name: store_name})

      start_supervised!(
        {AgentSupervisor,
         name: name,
         registry: registry,
         agents: [{A2A.Test.EchoAgent, task_store: {A2A.TaskStore.ETS, store_name}}]}
      )

      {:ok, task} = A2A.call(A2A.Test.EchoAgent, "hello")
      assert {:ok, ^task} = A2A.TaskStore.ETS.get(store_name, task.id)
    end
  end
end
