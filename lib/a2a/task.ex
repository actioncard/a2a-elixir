defmodule A2A.Task do
  @moduledoc """
  A unit of work managed by an agent runtime.

  Tasks track lifecycle state, message history, and produced artifacts.
  """

  @type state :: A2A.Task.Status.state()

  @type t :: %__MODULE__{
          id: String.t(),
          context_id: String.t() | nil,
          status: A2A.Task.Status.t(),
          history: [A2A.Message.t()],
          artifacts: [A2A.Artifact.t()],
          metadata: map()
        }

  @enforce_keys [:id, :status]
  defstruct [
    :id,
    :context_id,
    :status,
    history: [],
    artifacts: [],
    metadata: %{}
  ]

  @terminal_states [:completed, :canceled, :failed]

  @doc """
  Returns `true` if the task is in a terminal state.
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: %A2A.Task.Status{state: state}}) do
    state in @terminal_states
  end

  @doc """
  Truncates the task history to the last `n` entries.

  Returns the task unchanged when `n` is `nil`. A value of `0` clears
  the history entirely.
  """
  @spec truncate_history(t(), non_neg_integer() | nil) :: t()
  def truncate_history(task, nil), do: task
  def truncate_history(task, 0), do: %{task | history: []}

  def truncate_history(task, n) when is_integer(n) and n > 0 do
    %{task | history: Enum.take(task.history, -n)}
  end

  def truncate_history(task, _), do: task

  @doc """
  Strips the internal `:stream` key from task metadata.

  The `:stream` key holds a raw enumerable/function ref used by the SSE
  path and must be removed before JSON encoding.
  """
  @spec strip_stream_metadata(t()) :: t()
  def strip_stream_metadata(%{metadata: metadata} = task) do
    %{task | metadata: Map.delete(metadata, :stream)}
  end

  def strip_stream_metadata(task), do: task

  @doc """
  Creates a new task in the `:submitted` state.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      id: Keyword.get_lazy(opts, :id, fn -> A2A.ID.generate("tsk") end),
      context_id: Keyword.get(opts, :context_id),
      status: A2A.Task.Status.new(:submitted),
      history: Keyword.get(opts, :history, []),
      artifacts: Keyword.get(opts, :artifacts, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
