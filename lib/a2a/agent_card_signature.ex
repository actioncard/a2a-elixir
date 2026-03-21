defmodule A2A.AgentCardSignature do
  @moduledoc """
  A JWS signature of an AgentCard (RFC 7515).

  ## Proto Reference

      message AgentCardSignature {
        string protected = 1;   // base64url-encoded JSON header
        string signature = 2;   // base64url-encoded signature
        google.protobuf.Struct header = 3;  // unprotected header
      }
  """

  @type t :: %__MODULE__{
          protected: String.t(),
          signature: String.t(),
          header: map() | nil
        }

  @enforce_keys [:protected, :signature]
  defstruct [:protected, :signature, :header]
end
