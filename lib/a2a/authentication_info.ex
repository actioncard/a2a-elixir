defmodule A2A.AuthenticationInfo do
  @moduledoc """
  Authentication details used for push notifications.

  Contains an HTTP authentication scheme and optional credentials.

  ## Proto Reference

      message AuthenticationInfo {
        string scheme = 1;    // e.g. "Bearer", "Basic"
        string credentials = 2;
      }
  """

  @type t :: %__MODULE__{
          scheme: String.t(),
          credentials: String.t() | nil
        }

  @enforce_keys [:scheme]
  defstruct [:scheme, :credentials]
end
