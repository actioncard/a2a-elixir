defmodule A2A.Part do
  @moduledoc """
  Typed content parts used in messages and artifacts.

  Three variants exist:

  - `A2A.Part.Text` — plain text content
  - `A2A.Part.File` — file content (inline bytes or URI)
  - `A2A.Part.Data` — structured data (map)
  """

  @type t :: A2A.Part.Text.t() | A2A.Part.File.t() | A2A.Part.Data.t()
end

defmodule A2A.Part.Text do
  @moduledoc """
  A text content part.
  """

  @type t :: %__MODULE__{
          text: String.t(),
          metadata: map(),
          media_type: String.t() | nil,
          filename: String.t() | nil
        }

  defstruct text: "", metadata: %{}, media_type: nil, filename: nil

  @doc """
  Creates a new text part.
  """
  @spec new(String.t(), map()) :: t()
  def new(text, metadata \\ %{}) do
    %__MODULE__{text: text, metadata: metadata}
  end
end

defmodule A2A.Part.File do
  @moduledoc """
  A file content part.
  """

  @type t :: %__MODULE__{
          file: A2A.FileContent.t(),
          metadata: map(),
          media_type: String.t() | nil,
          filename: String.t() | nil
        }

  @enforce_keys [:file]
  defstruct file: nil, metadata: %{}, media_type: nil, filename: nil

  @doc """
  Creates a new file part.
  """
  @spec new(A2A.FileContent.t(), map()) :: t()
  def new(%A2A.FileContent{} = file, metadata \\ %{}) do
    %__MODULE__{file: file, metadata: metadata}
  end
end

defmodule A2A.Part.Data do
  @moduledoc """
  A structured data content part.
  """

  @type t :: %__MODULE__{
          data: map(),
          metadata: map(),
          media_type: String.t() | nil,
          filename: String.t() | nil
        }

  defstruct data: %{}, metadata: %{}, media_type: nil, filename: nil

  @doc """
  Creates a new data part.
  """
  @spec new(map(), map()) :: t()
  def new(data, metadata \\ %{}) when is_map(data) do
    %__MODULE__{data: data, metadata: metadata}
  end
end
