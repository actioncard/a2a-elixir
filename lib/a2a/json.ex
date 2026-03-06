defmodule A2A.JSON do
  @moduledoc """
  Codec for converting between Elixir structs and the A2A v0.3 camelCase JSON wire format.

  Produces intermediate maps (not JSON strings) suitable for composing with
  JSON-RPC envelopes. Use `Jason.encode!/1` on the result when you need a string.

  ## Encoding

      iex> part = A2A.Part.Text.new("hello")
      iex> {:ok, map} = A2A.JSON.encode(part)
      iex> map
      %{"kind" => "text", "text" => "hello"}

  ## Decoding

      iex> {:ok, part} = A2A.JSON.decode(%{"kind" => "text", "text" => "hello"}, :part)
      iex> part
      %A2A.Part.Text{text: "hello", metadata: %{}}
  """

  # v0.3 wire format: TASK_STATE_* prefixed enum values
  @state_to_string %{
    submitted: "TASK_STATE_SUBMITTED",
    working: "TASK_STATE_WORKING",
    input_required: "TASK_STATE_INPUT_REQUIRED",
    completed: "TASK_STATE_COMPLETED",
    canceled: "TASK_STATE_CANCELED",
    failed: "TASK_STATE_FAILED",
    rejected: "TASK_STATE_REJECTED",
    auth_required: "TASK_STATE_AUTH_REQUIRED",
    unknown: "TASK_STATE_UNKNOWN"
  }

  # Auto-derive canonical inverse, then merge legacy aliases
  @string_to_state @state_to_string
                   |> Map.new(fn {k, v} -> {v, k} end)
                   |> Map.merge(%{
                     # Legacy lowercase format
                     "submitted" => :submitted,
                     "working" => :working,
                     "input-required" => :input_required,
                     "completed" => :completed,
                     "canceled" => :canceled,
                     "failed" => :failed,
                     "rejected" => :rejected,
                     "auth-required" => :auth_required,
                     "unknown" => :unknown
                   })

  # v0.3 wire format: ROLE_* prefixed enum values
  @role_to_string %{user: "ROLE_USER", agent: "ROLE_AGENT"}

  @string_to_role @role_to_string
                  |> Map.new(fn {k, v} -> {v, k} end)
                  |> Map.merge(%{
                    # Legacy lowercase format
                    "user" => :user,
                    "agent" => :agent
                  })

  @doc """
  Returns the list of valid v0.3 wire-format state strings.
  """
  @spec valid_state_strings() :: [String.t()]
  def valid_state_strings, do: Map.values(@state_to_string)

  @doc """
  Decodes a wire-format state string to an atom.

  Accepts both v0.3 (`"TASK_STATE_WORKING"`) and legacy (`"working"`)
  formats.
  """
  @spec decode_state(String.t()) :: {:ok, atom()} | {:error, {:invalid_state, String.t()}}
  def decode_state(str) when is_map_key(@string_to_state, str) do
    {:ok, @string_to_state[str]}
  end

  def decode_state(str), do: {:error, {:invalid_state, str}}

  # -------------------------------------------------------------------
  # Encoding
  # -------------------------------------------------------------------

  @type encode_result :: {:ok, map()} | {:error, term()}

  @doc """
  Encodes an Elixir struct to a JSON-ready map.

  Returns `{:ok, map}` on success or `{:error, reason}` on failure.
  Optional `nil` fields and empty collections are omitted from the output.
  """
  @spec encode(struct()) :: encode_result()
  def encode(%A2A.Task{} = task) do
    {:ok, status} = encode(task.status)

    map =
      %{"kind" => "task", "id" => task.id, "contextId" => task.context_id, "status" => status}
      |> put_unless_empty("history", encode_list(task.history))
      |> put_unless_empty("artifacts", encode_list(task.artifacts))
      |> put_unless_empty("metadata", task.metadata)

    {:ok, map}
  end

  def encode(%A2A.Task.Status{} = status) do
    map =
      %{"state" => encode_state(status.state)}
      |> put_unless_nil_nested("message", status.message)
      |> put_unless_nil("timestamp", encode_timestamp(status.timestamp))

    {:ok, map}
  end

  def encode(%A2A.Message{} = msg) do
    map =
      %{
        "kind" => "message",
        "role" => Map.fetch!(@role_to_string, msg.role),
        "parts" => encode_list(msg.parts)
      }
      |> put_unless_nil("messageId", msg.message_id)
      |> put_unless_nil("taskId", msg.task_id)
      |> put_unless_nil("contextId", msg.context_id)
      |> put_unless_empty("metadata", msg.metadata)
      |> put_unless_empty("extensions", msg.extensions)

    {:ok, map}
  end

  def encode(%A2A.Artifact{} = artifact) do
    map =
      %{"parts" => encode_list(artifact.parts)}
      |> put_unless_nil("artifactId", artifact.artifact_id)
      |> put_unless_nil("name", artifact.name)
      |> put_unless_nil("description", artifact.description)
      |> put_unless_empty("metadata", artifact.metadata)

    {:ok, map}
  end

  def encode(%A2A.Part.Text{} = part) do
    map =
      %{"kind" => "text", "text" => part.text}
      |> put_unless_empty("metadata", part.metadata)

    {:ok, map}
  end

  def encode(%A2A.Part.File{} = part) do
    {:ok, file} = encode(part.file)

    map =
      %{"kind" => "file", "file" => file}
      |> put_unless_empty("metadata", part.metadata)

    {:ok, map}
  end

  def encode(%A2A.Part.Data{} = part) do
    map =
      %{"kind" => "data", "data" => part.data}
      |> put_unless_empty("metadata", part.metadata)

    {:ok, map}
  end

  def encode(%A2A.FileContent{} = fc) do
    map =
      %{}
      |> put_unless_nil("name", fc.name)
      |> put_unless_nil("mimeType", fc.mime_type)
      |> put_unless_nil("uri", fc.uri)
      |> put_unless_nil("bytes", encode_bytes(fc.bytes))

    {:ok, map}
  end

  def encode(%A2A.Event.StatusUpdate{} = event) do
    {:ok, status} = encode(event.status)

    map =
      %{
        "kind" => "status-update",
        "taskId" => event.task_id,
        "status" => status,
        "final" => event.final
      }
      |> put_unless_nil("contextId", event.context_id)
      |> put_unless_empty("metadata", event.metadata)

    {:ok, map}
  end

  def encode(%A2A.Event.ArtifactUpdate{} = event) do
    {:ok, artifact} = encode(event.artifact)

    map =
      %{
        "kind" => "artifact-update",
        "taskId" => event.task_id,
        "artifact" => artifact
      }
      |> put_unless_nil("contextId", event.context_id)
      |> put_unless_nil("append", event.append)
      |> put_unless_nil("lastChunk", event.last_chunk)
      |> put_unless_empty("metadata", event.metadata)

    {:ok, map}
  end

  def encode(%{__struct__: mod}) do
    {:error, {:unsupported_type, mod}}
  end

  @doc """
  Encodes an Elixir struct to a JSON-ready map, raising on failure.
  """
  @spec encode!(struct()) :: map()
  def encode!(struct) do
    case encode(struct) do
      {:ok, map} -> map
      {:error, reason} -> raise ArgumentError, "encode failed: #{inspect(reason)}"
    end
  end

  @doc """
  Encodes an agent card map with options into the AgentCard JSON format.

  ## Options

  - `:url` — the agent's endpoint URL (required)
  - `:capabilities` — `AgentCapabilities` map (default: `%{}`)
  - `:default_input_modes` — list of MIME types (default: `["text/plain"]`)
  - `:default_output_modes` — list of MIME types (default: `["text/plain"]`)
  - `:provider` — `%{organization: ..., url: ...}` map
  - `:documentation_url` — URL string
  - `:icon_url` — URL string
  - `:protocol_version` — protocol version string
  - `:supported_interfaces` — list of `%{url: ..., protocol_binding: ...,
    protocol_version: ...}` maps. Defaults to a single JSON-RPC interface
    derived from `:url`.
  - `:security_schemes` — `%{name => %SecurityScheme.X{}}` map
  - `:security` — list of `%{name => scopes}` maps (OpenAPI-style)
  """
  @spec encode_agent_card(A2A.Agent.card(), keyword()) :: map()
  def encode_agent_card(card, opts \\ []) do
    url = Keyword.fetch!(opts, :url)
    capabilities = Keyword.get(opts, :capabilities, %{})
    input_modes = Keyword.get(opts, :default_input_modes, ["text/plain"])
    output_modes = Keyword.get(opts, :default_output_modes, ["text/plain"])

    interfaces =
      Keyword.get(opts, :supported_interfaces) ||
        [%{url: url, protocol_binding: "jsonrpc", protocol_version: "2.0"}]

    security_schemes = Keyword.get(opts, :security_schemes, %{})
    security = Keyword.get(opts, :security, [])

    skills =
      Enum.map(card.skills, fn skill ->
        %{
          "id" => skill.id,
          "name" => skill.name,
          "description" => skill.description,
          "tags" => skill.tags
        }
      end)

    caps = encode_capabilities(capabilities)

    map =
      %{
        "name" => card.name,
        "description" => card.description,
        "url" => url,
        "version" => card.version,
        "skills" => skills,
        "capabilities" => caps,
        "defaultInputModes" => input_modes,
        "defaultOutputModes" => output_modes,
        "supportedInterfaces" => encode_interfaces(interfaces)
      }
      |> put_unless_nil("provider", encode_provider(Keyword.get(opts, :provider)))
      |> put_unless_nil("documentationUrl", Keyword.get(opts, :documentation_url))
      |> put_unless_nil("iconUrl", Keyword.get(opts, :icon_url))
      |> put_unless_nil("protocolVersion", Keyword.get(opts, :protocol_version))
      |> put_unless_empty("securitySchemes", encode_security_schemes(security_schemes))
      |> put_unless_empty("security", security)

    map
  end

  @doc """
  Decodes a JSON map into an `%A2A.AgentCard{}` struct.

  Returns `{:ok, agent_card}` on success or `{:error, reason}` on failure.

  ## Example

      iex> map = %{
      ...>   "name" => "test",
      ...>   "description" => "A test agent",
      ...>   "url" => "https://example.com",
      ...>   "version" => "1.0.0",
      ...>   "skills" => [
      ...>     %{"id" => "s1", "name" => "Skill", "description" => "Does things", "tags" => []}
      ...>   ]
      ...> }
      iex> {:ok, card} = A2A.JSON.decode_agent_card(map)
      iex> card.name
      "test"
  """
  @spec decode_agent_card(map()) :: {:ok, A2A.AgentCard.t()} | {:error, term()}
  def decode_agent_card(map) when is_map(map) do
    with {:ok, name} <- require_field(map, "name"),
         {:ok, description} <- require_field(map, "description"),
         {:ok, url} <- require_field(map, "url"),
         {:ok, version} <- require_field(map, "version"),
         {:ok, skills_list} <- require_field(map, "skills"),
         {:ok, skills} <- decode_card_skills(skills_list) do
      {:ok,
       %A2A.AgentCard{
         name: name,
         description: description,
         url: url,
         version: version,
         skills: skills,
         capabilities: decode_card_capabilities(Map.get(map, "capabilities", %{})),
         default_input_modes: Map.get(map, "defaultInputModes", ["text/plain"]),
         default_output_modes: Map.get(map, "defaultOutputModes", ["text/plain"]),
         provider: decode_card_provider(Map.get(map, "provider")),
         documentation_url: Map.get(map, "documentationUrl"),
         icon_url: Map.get(map, "iconUrl"),
         protocol_version: Map.get(map, "protocolVersion"),
         supported_interfaces: decode_card_interfaces(Map.get(map, "supportedInterfaces", [])),
         security_schemes: decode_card_security_schemes(Map.get(map, "securitySchemes", %{})),
         security: Map.get(map, "security", [])
       }}
    end
  end

  # -------------------------------------------------------------------
  # Decoding
  # -------------------------------------------------------------------

  @type decode_type ::
          :task
          | :status
          | :message
          | :artifact
          | :part
          | :file_content
          | :event
          | :status_update_event
          | :artifact_update_event

  @doc """
  Decodes a JSON map into an Elixir struct of the given type.

  Returns `{:ok, struct}` on success or `{:error, reason}` on failure.

  The `:part` type dispatches on the `"kind"` field, or infers the type
  from content fields (`"text"`, `"file"`, `"data"`) when `"kind"` is
  absent (v0.3 format). The `:event` type dispatches on `"kind"` to one
  of `"status-update"`, `"artifact-update"`, `"task"`, or `"message"`.
  """
  @spec decode(map(), decode_type()) :: {:ok, struct()} | {:error, term()}
  def decode(map, :task) do
    with {:ok, id} <- require_field(map, "id"),
         {:ok, status_map} <- require_field(map, "status"),
         {:ok, status} <- decode(status_map, :status),
         {:ok, history} <- decode_list(Map.get(map, "history", []), :message),
         {:ok, artifacts} <- decode_list(Map.get(map, "artifacts", []), :artifact) do
      {:ok,
       %A2A.Task{
         id: id,
         context_id: Map.get(map, "contextId"),
         status: status,
         history: history,
         artifacts: artifacts,
         metadata: Map.get(map, "metadata", %{})
       }}
    end
  end

  def decode(map, :status) do
    with {:ok, state_str} <- require_field(map, "state"),
         {:ok, state} <- decode_state(state_str),
         {:ok, message} <- decode_optional(Map.get(map, "message"), :message),
         {:ok, timestamp} <- decode_timestamp(Map.get(map, "timestamp")) do
      {:ok,
       %A2A.Task.Status{
         state: state,
         message: message,
         timestamp: timestamp
       }}
    end
  end

  def decode(map, :message) do
    with {:ok, role_str} <- require_field(map, "role"),
         {:ok, role} <- decode_role(role_str),
         {:ok, parts_list} <- require_field(map, "parts"),
         {:ok, parts} <- decode_list(parts_list, :part) do
      {:ok,
       %A2A.Message{
         message_id: Map.get(map, "messageId"),
         role: role,
         parts: parts,
         task_id: Map.get(map, "taskId"),
         context_id: Map.get(map, "contextId"),
         metadata: Map.get(map, "metadata", %{}),
         extensions: Map.get(map, "extensions", %{})
       }}
    end
  end

  def decode(map, :artifact) do
    with {:ok, parts_list} <- require_field(map, "parts"),
         {:ok, parts} <- decode_list(parts_list, :part) do
      {:ok,
       %A2A.Artifact{
         artifact_id: Map.get(map, "artifactId"),
         name: Map.get(map, "name"),
         description: Map.get(map, "description"),
         parts: parts,
         metadata: Map.get(map, "metadata", %{})
       }}
    end
  end

  def decode(map, :part) do
    case Map.get(map, "kind") do
      "text" -> decode_text_part(map)
      "file" -> decode_file_part(map)
      "data" -> decode_data_part(map)
      nil -> infer_part_type(map)
      other -> {:error, {:unknown_kind, other}}
    end
  end

  def decode(map, :file_content) do
    bytes_str = Map.get(map, "bytes") || Map.get(map, "fileWithBytes")

    with {:ok, bytes} <- decode_base64(bytes_str) do
      {:ok,
       %A2A.FileContent{
         name: Map.get(map, "name"),
         mime_type: Map.get(map, "mimeType") || Map.get(map, "mediaType"),
         bytes: bytes,
         uri: Map.get(map, "uri") || Map.get(map, "fileWithUri")
       }}
    end
  end

  def decode(map, :event) do
    case Map.get(map, "kind") do
      "status-update" -> decode(map, :status_update_event)
      "artifact-update" -> decode(map, :artifact_update_event)
      "task" -> decode(map, :task)
      "message" -> decode(map, :message)
      nil -> {:error, {:missing_field, "kind"}}
      other -> {:error, {:unknown_kind, other}}
    end
  end

  def decode(map, :status_update_event) do
    with {:ok, task_id} <- require_field(map, "taskId"),
         {:ok, status_map} <- require_field(map, "status"),
         {:ok, status} <- decode(status_map, :status),
         {:ok, final} <- require_field(map, "final") do
      {:ok,
       %A2A.Event.StatusUpdate{
         task_id: task_id,
         context_id: Map.get(map, "contextId"),
         status: status,
         final: final,
         metadata: Map.get(map, "metadata", %{})
       }}
    end
  end

  def decode(map, :artifact_update_event) do
    with {:ok, task_id} <- require_field(map, "taskId"),
         {:ok, artifact_map} <- require_field(map, "artifact"),
         {:ok, artifact} <- decode(artifact_map, :artifact) do
      {:ok,
       %A2A.Event.ArtifactUpdate{
         task_id: task_id,
         context_id: Map.get(map, "contextId"),
         artifact: artifact,
         append: Map.get(map, "append"),
         last_chunk: Map.get(map, "lastChunk"),
         metadata: Map.get(map, "metadata", %{})
       }}
    end
  end

  @doc """
  Decodes a JSON map into an Elixir struct, raising on failure.
  """
  @spec decode!(map(), decode_type()) :: struct()
  def decode!(map, type) do
    case decode(map, type) do
      {:ok, struct} -> struct
      {:error, reason} -> raise ArgumentError, "decode failed: #{inspect(reason)}"
    end
  end

  # -------------------------------------------------------------------
  # Private — Encoding helpers
  # -------------------------------------------------------------------

  defp encode_state(state) do
    Map.fetch!(@state_to_string, state)
  end

  defp encode_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_timestamp(nil), do: nil

  defp encode_bytes(nil), do: nil
  defp encode_bytes(bytes) when is_binary(bytes), do: Base.encode64(bytes)

  defp encode_list(items) do
    Enum.map(items, fn item ->
      {:ok, encoded} = encode(item)
      encoded
    end)
  end

  defp encode_capabilities(caps) when is_map(caps) do
    encode_known_keys(caps, [
      {"streaming", :streaming},
      {"pushNotifications", :push_notifications},
      {"stateTransitionHistory", :state_transition_history},
      {"extendedAgentCard", :extended_agent_card}
    ])
  end

  defp encode_interfaces(interfaces) when is_list(interfaces) do
    mappings = [
      {"url", :url},
      {"protocolBinding", :protocol_binding},
      {"protocolVersion", :protocol_version}
    ]

    Enum.map(interfaces, &encode_known_keys(&1, mappings))
  end

  defp encode_provider(nil), do: nil

  defp encode_provider(provider) when is_map(provider) do
    encode_known_keys(provider, [
      {"organization", :organization},
      {"url", :url}
    ])
  end

  defp encode_security_schemes(schemes) when map_size(schemes) == 0, do: %{}

  defp encode_security_schemes(schemes) when is_map(schemes) do
    Map.new(schemes, fn {name, scheme} ->
      {name, encode_security_scheme(scheme)}
    end)
  end

  defp encode_security_scheme(%A2A.SecurityScheme.APIKey{} = s) do
    %{"apiKeySecurityScheme" => %{"name" => s.name, "in" => s.in}}
  end

  defp encode_security_scheme(%A2A.SecurityScheme.HTTPAuth{} = s) do
    %{"httpAuthSecurityScheme" => %{"scheme" => s.scheme}}
  end

  defp encode_security_scheme(%A2A.SecurityScheme.OAuth2{} = s) do
    inner = %{"flows" => s.flows}

    inner =
      if s.oauth2_metadata_url,
        do: Map.put(inner, "oauth2MetadataUrl", s.oauth2_metadata_url),
        else: inner

    %{"oauth2SecurityScheme" => inner}
  end

  defp encode_security_scheme(%A2A.SecurityScheme.OpenIDConnect{} = s) do
    %{
      "openIdConnectSecurityScheme" => %{
        "openIdConnectUrl" => s.open_id_connect_url
      }
    }
  end

  defp encode_security_scheme(%A2A.SecurityScheme.MutualTLS{}) do
    %{"mtlsSecurityScheme" => %{}}
  end

  @doc """
  Converts an Elixir map with atom keys to a camelCase JSON map.

  Each mapping is a `{json_key, atom_key}` pair. Keys whose values are `nil`
  (or absent) are omitted from the result. Looks up both the atom key and the
  JSON-string key so the function works with either representation.
  """
  @spec encode_known_keys(map(), [{String.t(), atom()}]) :: map()
  def encode_known_keys(source, mappings) do
    Enum.reduce(mappings, %{}, fn {json_key, atom_key}, acc ->
      case Map.get(source, atom_key, Map.get(source, json_key)) do
        nil -> acc
        val -> Map.put(acc, json_key, val)
      end
    end)
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp put_unless_empty(map, _key, val) when val == %{}, do: map
  defp put_unless_empty(map, _key, val) when val == [], do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  defp put_unless_nil_nested(map, _key, nil), do: map

  defp put_unless_nil_nested(map, key, struct) do
    {:ok, encoded} = encode(struct)
    Map.put(map, key, encoded)
  end

  # -------------------------------------------------------------------
  # Private — Decoding helpers
  # -------------------------------------------------------------------

  defp require_field(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, field}}
    end
  end

  defp decode_role(str) when is_map_key(@string_to_role, str) do
    {:ok, @string_to_role[str]}
  end

  defp decode_role(str), do: {:error, {:invalid_role, str}}

  defp decode_timestamp(nil), do: {:ok, nil}

  defp decode_timestamp(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, {:invalid_timestamp, str}}
    end
  end

  defp decode_base64(nil), do: {:ok, nil}

  defp decode_base64(str) when is_binary(str) do
    case Base.decode64(str) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_base64}
    end
  end

  defp decode_optional(nil, _type), do: {:ok, nil}
  defp decode_optional(map, type), do: decode(map, type)

  defp decode_list(items, type) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case decode(item, type) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  # v0.3: parts may omit "kind" — infer from content field presence
  defp infer_part_type(map) do
    cond do
      Map.has_key?(map, "text") -> decode_text_part(map)
      Map.has_key?(map, "file") -> decode_file_part(map)
      Map.has_key?(map, "data") -> decode_data_part(map)
      true -> {:error, {:missing_field, "kind"}}
    end
  end

  defp decode_text_part(map) do
    with {:ok, text} <- require_field(map, "text") do
      {:ok,
       %A2A.Part.Text{
         text: text,
         metadata: Map.get(map, "metadata", %{})
       }}
    end
  end

  defp decode_file_part(map) do
    with {:ok, file_map} <- require_field(map, "file"),
         {:ok, file} <- decode(file_map, :file_content) do
      {:ok,
       %A2A.Part.File{
         file: file,
         metadata: Map.get(map, "metadata", %{})
       }}
    end
  end

  defp decode_data_part(map) do
    with {:ok, data} <- require_field(map, "data") do
      {:ok,
       %A2A.Part.Data{
         data: data,
         metadata: Map.get(map, "metadata", %{})
       }}
    end
  end

  # -------------------------------------------------------------------
  # Private — AgentCard decoding helpers
  # -------------------------------------------------------------------

  defp decode_card_skills(skills) when is_list(skills) do
    Enum.reduce_while(skills, {:ok, []}, fn skill, {:ok, acc} ->
      with {:ok, id} <- require_field(skill, "id"),
           {:ok, name} <- require_field(skill, "name"),
           {:ok, description} <- require_field(skill, "description") do
        decoded = %{
          id: id,
          name: name,
          description: description,
          tags: Map.get(skill, "tags", [])
        }

        {:cont, {:ok, [decoded | acc]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp decode_card_skills(_), do: {:error, {:invalid_field, "skills"}}

  defp decode_card_capabilities(nil), do: %{}

  defp decode_card_capabilities(map) when is_map(map) do
    decode_known_keys(map, [
      {"streaming", :streaming},
      {"pushNotifications", :push_notifications},
      {"stateTransitionHistory", :state_transition_history},
      {"extendedAgentCard", :extended_agent_card}
    ])
  end

  defp decode_card_interfaces(interfaces) when is_list(interfaces) do
    mappings = [
      {"url", :url},
      {"protocolBinding", :protocol_binding},
      {"protocolVersion", :protocol_version}
    ]

    Enum.map(interfaces, &decode_known_keys(&1, mappings))
  end

  defp decode_card_interfaces(_), do: []

  defp decode_card_provider(nil), do: nil

  defp decode_card_provider(map) when is_map(map) do
    decode_known_keys(map, [
      {"organization", :organization},
      {"url", :url}
    ])
  end

  defp decode_card_security_schemes(schemes) when map_size(schemes) == 0, do: %{}

  defp decode_card_security_schemes(schemes) when is_map(schemes) do
    Map.new(schemes, fn {name, scheme_map} ->
      {name, decode_security_scheme(scheme_map)}
    end)
  end

  defp decode_security_scheme(%{"apiKeySecurityScheme" => inner}) do
    %A2A.SecurityScheme.APIKey{
      name: Map.fetch!(inner, "name"),
      in: Map.fetch!(inner, "in")
    }
  end

  defp decode_security_scheme(%{"httpAuthSecurityScheme" => inner}) do
    %A2A.SecurityScheme.HTTPAuth{scheme: Map.fetch!(inner, "scheme")}
  end

  defp decode_security_scheme(%{"oauth2SecurityScheme" => inner}) do
    %A2A.SecurityScheme.OAuth2{
      flows: Map.fetch!(inner, "flows"),
      oauth2_metadata_url: Map.get(inner, "oauth2MetadataUrl")
    }
  end

  defp decode_security_scheme(%{"openIdConnectSecurityScheme" => inner}) do
    %A2A.SecurityScheme.OpenIDConnect{
      open_id_connect_url: Map.fetch!(inner, "openIdConnectUrl")
    }
  end

  defp decode_security_scheme(%{"mtlsSecurityScheme" => _}) do
    %A2A.SecurityScheme.MutualTLS{}
  end

  defp decode_known_keys(source, mappings) do
    Enum.reduce(mappings, %{}, fn {json_key, atom_key}, acc ->
      case Map.get(source, json_key) do
        nil -> acc
        val -> Map.put(acc, atom_key, val)
      end
    end)
  end
end
