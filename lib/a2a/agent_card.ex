defmodule A2A.AgentCard do
  @moduledoc """
  Decoded agent card from the A2A discovery endpoint.

  Contains the agent's identity, capabilities, and skills as returned by
  `GET /.well-known/agent-card.json`. This is the wire-format struct used
  by clients; server-side agents define their card via the `agent_card/0` callback.

  ## Example

      {:ok, card} = A2A.Client.discover("https://agent.example.com")
      card.name   #=> "my-agent"
      card.skills #=> [%{id: "greet", name: "Greet", ...}]
  """

  @type skill :: %{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          tags: [String.t()]
        }

  @type capabilities :: %{
          optional(:streaming) => boolean(),
          optional(:push_notifications) => boolean(),
          optional(:state_transition_history) => boolean(),
          optional(:extended_agent_card) => boolean()
        }

  @type provider :: %{
          organization: String.t(),
          url: String.t()
        }

  @type supported_interface :: %{
          url: String.t(),
          protocol_binding: String.t(),
          protocol_version: String.t()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          url: String.t(),
          version: String.t(),
          skills: [skill()],
          capabilities: capabilities(),
          default_input_modes: [String.t()],
          default_output_modes: [String.t()],
          provider: provider() | nil,
          documentation_url: String.t() | nil,
          icon_url: String.t() | nil,
          protocol_version: String.t() | nil,
          supported_interfaces: [supported_interface()],
          security_schemes: %{String.t() => A2A.SecurityScheme.t()},
          security: [%{String.t() => [String.t()]}]
        }

  @enforce_keys [:name, :description, :url, :version, :skills]
  defstruct [
    :name,
    :description,
    :url,
    :version,
    :provider,
    :documentation_url,
    :icon_url,
    :protocol_version,
    skills: [],
    capabilities: %{},
    default_input_modes: ["text/plain"],
    default_output_modes: ["text/plain"],
    supported_interfaces: [],
    security_schemes: %{},
    security: []
  ]
end
