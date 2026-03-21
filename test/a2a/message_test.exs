defmodule A2A.MessageTest do
  use ExUnit.Case, async: true

  alias A2A.Message
  alias A2A.Part

  describe "new_user/1" do
    test "creates a user message from a string" do
      msg = Message.new_user("hello")
      assert msg.role == :user
      assert [%Part.Text{text: "hello"}] = msg.parts
      assert String.starts_with?(msg.message_id, "msg-")
    end

    test "creates a user message from parts" do
      parts = [Part.Text.new("hello"), Part.Data.new(%{x: 1})]
      msg = Message.new_user(parts)
      assert msg.role == :user
      assert length(msg.parts) == 2
    end
  end

  describe "new_agent/1" do
    test "creates an agent message from a string" do
      msg = Message.new_agent("response")
      assert msg.role == :agent
      assert [%Part.Text{text: "response"}] = msg.parts
    end

    test "creates an agent message from parts" do
      msg = Message.new_agent([Part.Text.new("hi")])
      assert msg.role == :agent
    end
  end

  describe "text/1" do
    test "extracts text from first text part" do
      msg = Message.new_user("hello world")
      assert Message.text(msg) == "hello world"
    end

    test "returns nil when no text part exists" do
      msg = %Message{role: :user, parts: [Part.Data.new(%{x: 1})]}
      assert Message.text(msg) == nil
    end

    test "finds first text part among mixed parts" do
      parts = [Part.Data.new(%{}), Part.Text.new("found"), Part.Text.new("second")]
      msg = %Message{role: :agent, parts: parts}
      assert Message.text(msg) == "found"
    end
  end

  describe "struct defaults" do
    test "metadata defaults to empty map, extensions to empty list" do
      msg = Message.new_user("test")
      assert msg.metadata == %{}
      assert msg.extensions == []
      assert msg.reference_task_ids == []
    end

    test "task_id and context_id default to nil" do
      msg = Message.new_user("test")
      assert msg.task_id == nil
      assert msg.context_id == nil
    end
  end
end
