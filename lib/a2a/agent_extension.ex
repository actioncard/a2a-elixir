defmodule A2A.AgentExtension do
  @moduledoc """
  A declaration of a protocol extension supported by an Agent.

  Per the A2A v1.0 spec, agents declare supported extensions in their
  Agent Card. Extensions are identified by a URI and may be marked as
  required, meaning clients must understand and comply with the
  extension's requirements.

  ## Fields

    * `:uri` — the unique URI identifying the extension (required)
    * `:description` — a human-readable description of how the agent uses the extension
    * `:required` — if `true`, the client must support this extension (default: `false`)
    * `:params` — optional extension-specific configuration parameters

  ## Examples

      %A2A.AgentExtension{
        uri: "https://a2a-protocol.org/extensions/timestamp",
        description: "Adds timestamps to messages",
        required: false
      }

      %A2A.AgentExtension{
        uri: "https://a2a-protocol.org/extensions/secure-passport",
        description: "Requires secure passport for authentication",
        required: true,
        params: %{"version" => "1.0"}
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
