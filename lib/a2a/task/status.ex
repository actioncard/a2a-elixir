defmodule A2A.Task.Status do
  @moduledoc """
  The current status of a task, including state, optional message, and timestamp.
  """

  @type state ::
          :submitted
          | :working
          | :input_required
          | :completed
          | :canceled
          | :failed
          | :rejected
          | :auth_required
          | :unknown

  @type t :: %__MODULE__{
          state: state(),
          message: A2A.Message.t() | nil,
          timestamp: DateTime.t()
        }

  @enforce_keys [:state, :timestamp]
  defstruct [:state, :message, :timestamp]

  @doc """
  Creates a new status with the given state and current timestamp.
  """
  @spec new(state(), A2A.Message.t() | nil) :: t()
  def new(state, message \\ nil) do
    %__MODULE__{
      state: state,
      message: message,
      timestamp: DateTime.utc_now()
    }
  end
end
