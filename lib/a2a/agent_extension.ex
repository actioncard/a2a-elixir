defmodule A2A.AgentExtension do
  @moduledoc """
  A declaration of a protocol extension supported by an Agent.

  ## Proto Reference

      message AgentExtension {
        string uri = 1;
        string description = 2;
        bool required = 3;
        google.protobuf.Struct params = 4;
      }
  """

  @type t :: %__MODULE__{
          uri: String.t(),
          description: String.t() | nil,
          required: boolean(),
          params: map() | nil
        }

  @enforce_keys [:uri]
  defstruct [:uri, :description, :params, required: false]
end
