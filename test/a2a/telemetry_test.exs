defmodule A2A.TelemetryTest do
  use ExUnit.Case, async: true

  defmodule CancelableAgent do
    @moduledoc false
    use A2A.Agent,
      name: "cancelable",
      description: "Supports cancel",
      skills: []

    @impl A2A.Agent
    def handle_message(_message, _context) do
      {:input_required, [A2A.Part.Text.new("waiting")]}
    end

    @impl A2A.Agent
    def handle_cancel(_context), do: :ok
  end

  setup do
    test_pid = self()

    attach = fn event_name, handler_id ->
      :telemetry.attach(
        handler_id,
        event_name,
        fn name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    %{attach: attach}
  end

  describe "[:a2a, :agent, :call] span" do
    test "fires start+stop for call/3", %{attach: attach} do
      attach.([:a2a, :agent, :call, :start], "call-start-1")
      attach.([:a2a, :agent, :call, :stop], "call-stop-1")

      {:ok, pid} = A2A.Test.EchoAgent.start_link(name: nil)
      {:ok, task} = A2A.call(pid, "hi")

      assert_received {:telemetry, [:a2a, :agent, :call, :start], %{system_time: _},
                       %{agent: ^pid, streaming: false}}

      assert_received {:telemetry, [:a2a, :agent, :call, :stop], %{duration: duration},
                       %{task_id: task_id, status: :completed, streaming: false}}

      assert is_integer(duration)
      assert task_id == task.id
    end

    test "fires start+stop for stream/3", %{attach: attach} do
      attach.([:a2a, :agent, :call, :start], "call-start-2")
      attach.([:a2a, :agent, :call, :stop], "call-stop-2")

      {:ok, pid} = A2A.Test.StreamAgent.start_link(name: nil)
      {:ok, _task, stream} = A2A.stream(pid, "go")

      assert_received {:telemetry, [:a2a, :agent, :call, :start], _,
                       %{agent: ^pid, streaming: true}}

      assert_received {:telemetry, [:a2a, :agent, :call, :stop], %{duration: _},
                       %{streaming: true, task_id: _}}

      # Consume stream to clean up
      Stream.run(stream)
    end

    test "includes error metadata on failure", %{attach: attach} do
      attach.([:a2a, :agent, :call, :stop], "call-stop-err")

      {:ok, pid} = A2A.Test.ErrorAgent.start_link(name: nil)
      {:ok, _task} = A2A.call(pid, "fail")

      assert_received {:telemetry, [:a2a, :agent, :call, :stop], %{duration: _},
                       %{status: :failed}}
    end
  end

  describe "[:a2a, :agent, :message] span" do
    test "fires start+stop with reply_type", %{attach: attach} do
      attach.([:a2a, :agent, :message, :start], "msg-start-1")
      attach.([:a2a, :agent, :message, :stop], "msg-stop-1")

      {:ok, pid} = A2A.Test.EchoAgent.start_link(name: nil)
      {:ok, task} = A2A.call(pid, "hi")

      assert_received {:telemetry, [:a2a, :agent, :message, :start], %{system_time: _},
                       %{agent: A2A.Test.EchoAgent, task_id: _, context_id: _}}

      assert_received {:telemetry, [:a2a, :agent, :message, :stop], %{duration: _},
                       %{agent: A2A.Test.EchoAgent, reply_type: :reply, task_id: task_id}}

      assert task_id == task.id
    end

    test "reports :stream reply_type", %{attach: attach} do
      attach.([:a2a, :agent, :message, :stop], "msg-stop-stream")

      {:ok, pid} = A2A.Test.StreamAgent.start_link(name: nil)
      {:ok, _task, stream} = A2A.stream(pid, "go")

      assert_received {:telemetry, [:a2a, :agent, :message, :stop], _, %{reply_type: :stream}}

      Stream.run(stream)
    end

    test "reports :input_required reply_type", %{attach: attach} do
      attach.([:a2a, :agent, :message, :stop], "msg-stop-ir")

      {:ok, pid} = A2A.Test.MultiTurnAgent.start_link(name: nil)
      {:ok, _task} = A2A.call(pid, "order pizza")

      assert_received {:telemetry, [:a2a, :agent, :message, :stop], _,
                       %{reply_type: :input_required}}
    end

    test "reports :error reply_type", %{attach: attach} do
      attach.([:a2a, :agent, :message, :stop], "msg-stop-err")

      {:ok, pid} = A2A.Test.ErrorAgent.start_link(name: nil)
      {:ok, _task} = A2A.call(pid, "fail")

      assert_received {:telemetry, [:a2a, :agent, :message, :stop], _, %{reply_type: :error}}
    end
  end

  describe "[:a2a, :agent, :cancel] span" do
    test "fires start+stop on cancel", %{attach: attach} do
      attach.([:a2a, :agent, :cancel, :start], "cancel-start-1")
      attach.([:a2a, :agent, :cancel, :stop], "cancel-stop-1")

      {:ok, pid} = CancelableAgent.start_link(name: nil)
      {:ok, task} = A2A.call(pid, "hi")
      :ok = GenServer.call(pid, {:cancel, task.id})

      assert_received {:telemetry, [:a2a, :agent, :cancel, :start], %{system_time: _},
                       %{agent: CancelableAgent, task_id: task_id}}

      assert task_id == task.id

      assert_received {:telemetry, [:a2a, :agent, :cancel, :stop], %{duration: _},
                       %{agent: CancelableAgent, task_id: ^task_id}}
    end
  end

  describe "[:a2a, :task, :transition]" do
    test "fires for each state transition", %{attach: attach} do
      attach.([:a2a, :task, :transition], "transition-1")

      {:ok, pid} = A2A.Test.EchoAgent.start_link(name: nil)
      {:ok, task} = A2A.call(pid, "hi")

      # submitted -> working -> completed
      assert_received {:telemetry, [:a2a, :task, :transition], %{system_time: _},
                       %{task_id: task_id, from: :submitted, to: :working}}

      assert_received {:telemetry, [:a2a, :task, :transition], %{system_time: _},
                       %{task_id: ^task_id, from: :working, to: :completed}}

      assert task_id == task.id
    end

    test "fires for multi-turn transitions", %{attach: attach} do
      attach.([:a2a, :task, :transition], "transition-mt")

      {:ok, pid} = A2A.Test.MultiTurnAgent.start_link(name: nil)
      {:ok, task} = A2A.call(pid, "order pizza")

      # submitted -> working -> input_required
      assert_received {:telemetry, [:a2a, :task, :transition], _,
                       %{task_id: _, from: :submitted, to: :working}}

      assert_received {:telemetry, [:a2a, :task, :transition], _,
                       %{task_id: _, from: :working, to: :input_required}}

      # Continue — working -> completed
      {:ok, _task} = A2A.call(pid, "large", task_id: task.id)

      assert_received {:telemetry, [:a2a, :task, :transition], _,
                       %{task_id: _, from: :input_required, to: :working}}

      assert_received {:telemetry, [:a2a, :task, :transition], _,
                       %{task_id: _, from: :working, to: :completed}}
    end

    test "fires for cancel transition", %{attach: attach} do
      attach.([:a2a, :task, :transition], "transition-cancel")

      {:ok, pid} = CancelableAgent.start_link(name: nil)
      {:ok, task} = A2A.call(pid, "hi")

      # Drain working + input_required transitions
      assert_received {:telemetry, [:a2a, :task, :transition], _, %{to: :working}}
      assert_received {:telemetry, [:a2a, :task, :transition], _, %{to: :input_required}}

      :ok = GenServer.call(pid, {:cancel, task.id})

      assert_received {:telemetry, [:a2a, :task, :transition], _,
                       %{from: :input_required, to: :canceled}}
    end

    test "fires for error transition", %{attach: attach} do
      attach.([:a2a, :task, :transition], "transition-err")

      {:ok, pid} = A2A.Test.ErrorAgent.start_link(name: nil)
      {:ok, _task} = A2A.call(pid, "fail")

      assert_received {:telemetry, [:a2a, :task, :transition], _, %{to: :working}}
      assert_received {:telemetry, [:a2a, :task, :transition], _, %{to: :failed}}
    end
  end

  describe "exception events" do
    defmodule CrashingAgent do
      @moduledoc false
      use A2A.Agent,
        name: "crasher",
        description: "Crashes on message",
        skills: []

      @impl A2A.Agent
      def handle_message(_message, _context) do
        raise "boom"
      end
    end

    test "message span fires exception on crash", %{attach: attach} do
      attach.([:a2a, :agent, :message, :exception], "msg-exc-1")

      Process.flag(:trap_exit, true)
      {:ok, pid} = CrashingAgent.start_link(name: nil)

      catch_exit(A2A.call(pid, "crash"))

      assert_receive {:telemetry, [:a2a, :agent, :message, :exception], %{duration: _},
                      %{agent: CrashingAgent, kind: _, reason: _, stacktrace: _}}
    end
  end
end
