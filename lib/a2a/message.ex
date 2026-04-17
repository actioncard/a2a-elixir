defmodule A2A.Message do
  @moduledoc """
  A single turn of communication between user and agent.

  Messages contain typed parts and are identified by role (`:user` or `:agent`).
  """

  @type role :: :user | :agent

  @type t :: %__MODULE__{
          message_id: String.t(),
          role: role(),
          parts: [A2A.Part.t()],
          task_id: String.t() | nil,
          context_id: String.t() | nil,
          metadata: map(),
          extensions: [String.t()] | map(),
          reference_task_ids: [String.t()]
        }

  @enforce_keys [:role, :parts]
  defstruct [
    :message_id,
    :role,
    :task_id,
    :context_id,
    parts: [],
    metadata: %{},
    extensions: [],
    reference_task_ids: []
  ]

  @doc """
  Creates a new user message from text or parts.
  """
  @spec new_user(String.t() | [A2A.Part.t()]) :: t()
  def new_user(text) when is_binary(text) do
    new_user([A2A.Part.Text.new(text)])
  end

  def new_user(parts) when is_list(parts) do
    %__MODULE__{
      message_id: A2A.ID.generate("msg"),
      role: :user,
      parts: parts
    }
  end

  @doc """
  Creates a new agent message from text or parts.
  """
  @spec new_agent(String.t() | [A2A.Part.t()]) :: t()
  def new_agent(text) when is_binary(text) do
    new_agent([A2A.Part.Text.new(text)])
  end

  def new_agent(parts) when is_list(parts) do
    %__MODULE__{
      message_id: A2A.ID.generate("msg"),
      role: :agent,
      parts: parts
    }
  end

  @doc """
  Extracts the text from the first `A2A.Part.Text` part, or `nil` if none.
  """
  @spec text(t()) :: String.t() | nil
  def text(%__MODULE__{parts: parts}) do
    Enum.find_value(parts, fn
      %A2A.Part.Text{text: text} -> text
      _ -> nil
    end)
  end
end
