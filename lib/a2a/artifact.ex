defmodule A2A.Artifact do
  @moduledoc """
  An output produced by an agent in response to a task.

  Artifacts contain typed parts representing the result of agent work.
  """

  @type t :: %__MODULE__{
          artifact_id: String.t(),
          name: String.t() | nil,
          description: String.t() | nil,
          parts: [A2A.Part.t()],
          metadata: map(),
          extensions: [String.t()]
        }

  @enforce_keys [:parts]
  defstruct [
    :artifact_id,
    :name,
    :description,
    parts: [],
    metadata: %{},
    extensions: []
  ]

  @doc """
  Creates a new artifact from parts.
  """
  @spec new([A2A.Part.t()], keyword()) :: t()
  def new(parts, opts \\ []) do
    %__MODULE__{
      artifact_id: A2A.ID.generate("art"),
      parts: parts,
      name: Keyword.get(opts, :name),
      description: Keyword.get(opts, :description),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
