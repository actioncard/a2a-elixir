defmodule A2A.Task.StatusTest do
  use ExUnit.Case, async: true

  alias A2A.Task.Status

  describe "new/1" do
    test "creates a status with the given state and current timestamp" do
      status = Status.new(:working)
      assert status.state == :working
      assert status.message == nil
      assert %DateTime{} = status.timestamp
      # Timestamp should be very recent (within last second)
      assert DateTime.diff(DateTime.utc_now(), status.timestamp, :millisecond) < 1000
    end

    test "works with all valid states" do
      for state <- [:submitted, :working, :input_required, :completed, :canceled, :failed,
                    :rejected, :auth_required, :unknown] do
        status = Status.new(state)
        assert status.state == state
      end
    end
  end

  describe "new/2" do
    test "creates a status with an optional message" do
      msg = A2A.Message.new_agent("processing")
      status = Status.new(:working, msg)
      assert status.state == :working
      assert status.message == msg
      assert %DateTime{} = status.timestamp
    end

    test "accepts nil message explicitly" do
      status = Status.new(:submitted, nil)
      assert status.state == :submitted
      assert status.message == nil
    end
  end

  describe "struct" do
    test "enforces :state and :timestamp keys" do
      assert_raise ArgumentError, fn ->
        struct!(Status, state: :working)
      end

      assert_raise ArgumentError, fn ->
        struct!(Status, timestamp: DateTime.utc_now())
      end
    end

    test "can be constructed directly with all required keys" do
      ts = ~U[2026-01-01 00:00:00Z]
      status = %Status{state: :completed, timestamp: ts}
      assert status.state == :completed
      assert status.timestamp == ts
      assert status.message == nil
    end
  end
end
