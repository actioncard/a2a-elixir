defmodule A2A.AuthenticationInfo do
  @moduledoc "Authentication details for push notifications."

  @type t :: %__MODULE__{scheme: String.t(), credentials: String.t() | nil}

  @enforce_keys [:scheme]
  defstruct [:scheme, :credentials]
end
