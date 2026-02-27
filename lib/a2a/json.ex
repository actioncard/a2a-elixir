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
      %A2A.Part.Text{kind: :text, text: "hello", metadata: %{}}
  """

  # State atoms that differ from their wire string representation
  @state_to_string %{
    input_required: "input-required",
    auth_required: "auth-required"
  }

  @string_to_state %{
    "input-required" => :input_required,
    "auth-required" => :auth_required
  }

  @valid_states ~w(
    submitted working input-required completed
    canceled failed rejected auth-required unknown
  )

  @valid_roles ~w(user agent)

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
      %{"kind" => "task", "id" => task.id, "status" => status}
      |> put_unless_nil("contextId", task.context_id)
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
        "role" => Atom.to_string(msg.role),
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
  """
  @spec encode_agent_card(A2A.Agent.card(), keyword()) :: map()
  def encode_agent_card(card, opts \\ []) do
    url = Keyword.fetch!(opts, :url)
    capabilities = Keyword.get(opts, :capabilities, %{})
    input_modes = Keyword.get(opts, :default_input_modes, ["text/plain"])
    output_modes = Keyword.get(opts, :default_output_modes, ["text/plain"])

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
        "defaultOutputModes" => output_modes
      }
      |> put_unless_nil("provider", encode_provider(Keyword.get(opts, :provider)))
      |> put_unless_nil("documentationUrl", Keyword.get(opts, :documentation_url))
      |> put_unless_nil("iconUrl", Keyword.get(opts, :icon_url))
      |> put_unless_nil("protocolVersion", Keyword.get(opts, :protocol_version))

    map
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

  The `:part` type dispatches on the `"kind"` field. The `:event` type
  dispatches on `"kind"` to one of `"status-update"`, `"artifact-update"`,
  `"task"`, or `"message"`.
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
      nil -> {:error, {:missing_field, "kind"}}
      other -> {:error, {:unknown_kind, other}}
    end
  end

  def decode(map, :file_content) do
    bytes_str = Map.get(map, "bytes")

    with {:ok, bytes} <- decode_base64(bytes_str) do
      {:ok,
       %A2A.FileContent{
         name: Map.get(map, "name"),
         mime_type: Map.get(map, "mimeType"),
         bytes: bytes,
         uri: Map.get(map, "uri")
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
    Map.get(@state_to_string, state, Atom.to_string(state))
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
    map = %{}

    map =
      case Map.get(caps, :streaming, Map.get(caps, "streaming")) do
        nil -> map
        val -> Map.put(map, "streaming", val)
      end

    map =
      case Map.get(caps, :push_notifications, Map.get(caps, "pushNotifications")) do
        nil -> map
        val -> Map.put(map, "pushNotifications", val)
      end

    map =
      case Map.get(
             caps,
             :state_transition_history,
             Map.get(caps, "stateTransitionHistory")
           ) do
        nil -> map
        val -> Map.put(map, "stateTransitionHistory", val)
      end

    map
  end

  defp encode_provider(nil), do: nil

  defp encode_provider(provider) when is_map(provider) do
    org = Map.get(provider, :organization, Map.get(provider, "organization"))
    url = Map.get(provider, :url, Map.get(provider, "url"))
    %{"organization" => org, "url" => url}
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

  defp decode_state(str) when is_map_key(@string_to_state, str) do
    {:ok, @string_to_state[str]}
  end

  defp decode_state(str) when str in @valid_states do
    {:ok, String.to_existing_atom(str)}
  end

  defp decode_state(str), do: {:error, {:invalid_state, str}}

  defp decode_role(str) when str in @valid_roles do
    {:ok, String.to_existing_atom(str)}
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
end
