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
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:tags) => [String.t()],
          optional(:examples) => [String.t()],
          optional(:input_modes) => [String.t()],
          optional(:output_modes) => [String.t()],
          optional(:security_requirements) => [map()]
        }

  @type capabilities :: %{
          optional(:streaming) => boolean(),
          optional(:push_notifications) => boolean(),
          optional(:state_transition_history) => boolean(),
          optional(:extended_agent_card) => boolean(),
          optional(:extensions) => [A2A.AgentExtension.t()]
        }

  @type provider :: %{
          organization: String.t(),
          url: String.t()
        }

  @type supported_interface :: %{
          required(:url) => String.t(),
          required(:protocol_binding) => String.t(),
          required(:protocol_version) => String.t(),
          optional(:tenant) => String.t()
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
          security: [%{String.t() => [String.t()]}],
          signatures: [A2A.AgentCardSignature.t()],
          security_requirements: [map()]
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
    security: [],
    signatures: [],
    security_requirements: []
  ]

  @doc """
  Converts an AgentCard struct to a JSON-friendly string-keyed map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = card) do
    card
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {to_json_key(k), v} end)
    |> Map.new()
  end

  defp to_json_key(:default_input_modes), do: "defaultInputModes"
  defp to_json_key(:default_output_modes), do: "defaultOutputModes"
  defp to_json_key(:documentation_url), do: "documentationUrl"
  defp to_json_key(:icon_url), do: "iconUrl"
  defp to_json_key(:protocol_version), do: "protocolVersion"
  defp to_json_key(:supported_interfaces), do: "supportedInterfaces"
  defp to_json_key(:security_schemes), do: "securitySchemes"
  defp to_json_key(:security_requirements), do: "securityRequirements"
  defp to_json_key(key), do: to_string(key)
end
