defmodule A2A.Event do
  @moduledoc """
  Streaming events emitted during task execution.

  Three variants exist:

  - `A2A.Event.StatusUpdate` — task status changed
  - `A2A.Event.ArtifactUpdate` — artifact produced or appended
  - `A2A.Message` — the agent answered out-of-band with a bare message, so
    the stream carries it alone and there is no task to update
  """

  @type t :: A2A.Event.StatusUpdate.t() | A2A.Event.ArtifactUpdate.t() | A2A.Message.t()
end

defmodule A2A.Event.StatusUpdate do
  @moduledoc """
  A streaming event indicating a task status change.
  """

  @type t :: %__MODULE__{
          task_id: String.t(),
          context_id: String.t() | nil,
          status: A2A.Task.Status.t(),
          final: boolean(),
          metadata: map()
        }

  @enforce_keys [:task_id, :status, :final]
  defstruct [
    :task_id,
    :context_id,
    :status,
    final: false,
    metadata: %{}
  ]

  @doc """
  Creates a new status update event.
  """
  @spec new(String.t(), A2A.Task.Status.t(), keyword()) :: t()
  def new(task_id, status, opts \\ []) do
    %__MODULE__{
      task_id: task_id,
      context_id: Keyword.get(opts, :context_id),
      status: status,
      final: Keyword.get(opts, :final, false),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end

defmodule A2A.Event.ArtifactUpdate do
  @moduledoc """
  A streaming event indicating an artifact was produced or appended.
  """

  @type t :: %__MODULE__{
          task_id: String.t(),
          context_id: String.t() | nil,
          artifact: A2A.Artifact.t(),
          append: boolean() | nil,
          last_chunk: boolean() | nil,
          metadata: map()
        }

  @enforce_keys [:task_id, :artifact]
  defstruct [
    :task_id,
    :context_id,
    :artifact,
    :append,
    :last_chunk,
    metadata: %{}
  ]

  @doc """
  Creates a new artifact update event.
  """
  @spec new(String.t(), A2A.Artifact.t(), keyword()) :: t()
  def new(task_id, artifact, opts \\ []) do
    %__MODULE__{
      task_id: task_id,
      context_id: Keyword.get(opts, :context_id),
      artifact: artifact,
      append: Keyword.get(opts, :append),
      last_chunk: Keyword.get(opts, :last_chunk),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
