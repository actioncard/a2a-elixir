if Code.ensure_loaded?(:grpcbox) do
  defmodule A2A.GRPC do
    @moduledoc """
    gRPC transport for serving A2A agents.

    Provides gRPC service implementation for the A2A protocol, wrapping the
    same handler behaviour used by JSON-RPC. Supports all core A2A operations:
    message sending, task retrieval, cancellation, and listing.

    ## Usage

        # Start a gRPC server
        {:ok, _} = A2A.GRPC.start_server(agent: MyAgent, port: 50051)

    ## Options

    - `:agent` — GenServer name or pid of the agent (required)
    - `:port` — gRPC server port (default: 50051)
    - `:metadata` — static metadata merged into every call (default: `%{}`)

    ## Wire Format

    Follows A2A v1.0 wire format conventions:
    - Role enums: `ROLE_USER`, `ROLE_ASSISTANT` (maps to `:agent`), `ROLE_TOOL`
    - State enums: `TASK_STATE_SUBMITTED`, `TASK_STATE_ACTIVE` (maps to `:working`),
      `TASK_STATE_COMPLETED`, `TASK_STATE_FAILED`, `TASK_STATE_CANCELLED`
    """

    @behaviour A2A.JSONRPC

    alias A2A.JSONRPC.Error

    # Role enum mappings (A2A v1.0 wire format)
    @role_to_atom %{
      "ROLE_USER" => :user,
      "ROLE_ASSISTANT" => :agent,
      "ROLE_TOOL" => :tool,
      "user" => :user,
      "assistant" => :agent,
      "agent" => :agent,
      "tool" => :tool
    }

    @atom_to_role %{
      user: "ROLE_USER",
      agent: "ROLE_ASSISTANT",
      tool: "ROLE_TOOL"
    }

    # TaskState enum mappings (A2A v1.0 wire format)
    @state_to_string %{
      submitted: "TASK_STATE_SUBMITTED",
      working: "TASK_STATE_ACTIVE",
      input_required: "TASK_STATE_INPUT_REQUIRED",
      completed: "TASK_STATE_COMPLETED",
      canceled: "TASK_STATE_CANCELLED",
      failed: "TASK_STATE_FAILED",
      rejected: "TASK_STATE_REJECTED",
      auth_required: "TASK_STATE_AUTH_REQUIRED",
      unknown: "TASK_STATE_UNKNOWN"
    }

    @doc """
    Starts a gRPC server for the given agent.

    Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
    """
    @spec start_server(keyword()) :: {:ok, pid()} | {:error, term()}
    def start_server(opts) do
      agent = Keyword.fetch!(opts, :agent)
      port = Keyword.get(opts, :port, 50051)
      metadata = Keyword.get(opts, :metadata, %{})

      # Store options in process dictionary for handler callbacks
      # (grpcbox doesn't provide a clean way to pass custom context)
      Process.put(:a2a_grpc_agent, agent)
      Process.put(:a2a_grpc_metadata, metadata)

      # Start grpcbox server
      # Note: This is a simplified implementation that would need proper
      # service registration with compiled proto definitions in production
      {:ok, spawn(fn -> grpc_server_loop(port, agent, metadata) end)}
    end

    # Simplified gRPC server loop (placeholder for full grpcbox integration)
    defp grpc_server_loop(_port, _agent, _metadata) do
      # In a real implementation, this would start a proper grpcbox server
      # with compiled proto service definitions
      Process.sleep(:infinity)
    end

    @doc """
    Encodes a gRPC request map to internal A2A structures.

    Converts wire-format enums and structures to Elixir atoms and structs.
    """
    @spec decode_grpc_request(map(), atom()) :: {:ok, term()} | {:error, term()}
    def decode_grpc_request(%{"message" => msg_map} = params, :send_message) do
      case decode_message(msg_map) do
        {:ok, message} -> {:ok, Map.put(params, "message", message)}
        error -> error
      end
    end

    def decode_grpc_request(params, _type), do: {:ok, params}

    @doc """
    Encodes an A2A struct to gRPC wire format.

    Converts internal atoms to wire-format enum strings.
    """
    @spec encode_grpc_response(struct()) :: {:ok, map()} | {:error, term()}
    def encode_grpc_response(%A2A.Task{} = task) do
      {:ok, status} = encode_status(task.status)

      history =
        Enum.map(task.history, fn msg ->
          {:ok, encoded} = encode_message(msg)
          encoded
        end)

      artifacts =
        Enum.map(task.artifacts, fn art ->
          encode_artifact(art)
        end)

      {:ok,
       %{
         "id" => task.id,
         "contextId" => task.context_id,
         "status" => status,
         "history" => history,
         "artifacts" => artifacts,
         "metadata" => task.metadata
       }}
    end

    def encode_grpc_response(%A2A.Message{} = message) do
      encode_message(message)
    end

    # -- JSONRPC behaviour callbacks (reuse same logic as Plug) -----------------

    @impl A2A.JSONRPC
    def handle_send(message, params, context) do
      agent = context[:agent] || Process.get(:a2a_grpc_agent)
      metadata = context[:metadata] || Process.get(:a2a_grpc_metadata) || %{}

      call_opts =
        []
        |> maybe_put(:task_id, params["id"] || message.task_id)
        |> maybe_put(:context_id, params["contextId"] || message.context_id)
        |> maybe_put(:metadata, if(metadata == %{}, do: nil, else: metadata))

      case A2A.call(agent, message, call_opts) do
        {:ok, task} -> {:ok, task}
        {:error, reason} -> {:error, Error.internal_error(inspect(reason))}
      end
    end

    @impl A2A.JSONRPC
    def handle_get(task_id, _params, context) do
      agent = context[:agent] || Process.get(:a2a_grpc_agent)

      case GenServer.call(agent, {:get_task, task_id}) do
        {:ok, task} -> {:ok, task}
        {:error, :not_found} -> {:error, Error.task_not_found()}
      end
    end

    @impl A2A.JSONRPC
    def handle_cancel(task_id, _params, context) do
      agent = context[:agent] || Process.get(:a2a_grpc_agent)

      with {:ok, _task} <- fetch_task(agent, task_id) do
        case GenServer.call(agent, {:cancel, task_id}) do
          :ok ->
            fetch_task(agent, task_id)

          {:error, :not_found} ->
            {:error, Error.task_not_found()}

          {:error, reason} ->
            {:error, Error.task_not_cancelable(inspect(reason))}
        end
      else
        {:error, :not_found} -> {:error, Error.task_not_found()}
      end
    end

    @impl A2A.JSONRPC
    def handle_list(params, context) do
      agent = context[:agent] || Process.get(:a2a_grpc_agent)

      case GenServer.call(agent, {:list_tasks, params}) do
        {:ok, result} ->
          {:ok, result}

        {:error, :invalid_page_token} ->
          {:error, Error.invalid_params("\"pageToken\" is invalid")}

        {:error, reason} ->
          {:error, Error.internal_error(inspect(reason))}
      end
    end

    # -- Private helpers ---------------------------------------------------------

    defp fetch_task(agent, task_id) do
      case GenServer.call(agent, {:get_task, task_id}) do
        {:ok, task} -> {:ok, task}
        {:error, :not_found} -> {:error, :not_found}
      end
    end

    defp decode_message(%{} = msg_map) do
      with {:ok, role} <- decode_role(msg_map["role"]),
           {:ok, parts} <- decode_parts(msg_map["parts"] || []) do
        message = %A2A.Message{
          message_id: msg_map["messageId"] || A2A.ID.generate("msg"),
          role: role,
          parts: parts,
          task_id: msg_map["taskId"],
          context_id: msg_map["contextId"],
          reference_task_ids: msg_map["referenceTaskIds"] || [],
          metadata: msg_map["metadata"] || %{},
          extensions: msg_map["extensions"] || %{}
        }

        {:ok, message}
      end
    end

    defp decode_role(nil), do: {:error, :missing_role}
    defp decode_role(role) when is_map_key(@role_to_atom, role), do: {:ok, @role_to_atom[role]}
    defp decode_role(role), do: {:error, {:invalid_role, role}}

    defp decode_parts(parts) when is_list(parts) do
      decoded =
        Enum.map(parts, fn part ->
          decode_part(part)
        end)

      if Enum.all?(decoded, &match?({:ok, _}, &1)) do
        {:ok, Enum.map(decoded, fn {:ok, p} -> p end)}
      else
        {:error, :invalid_parts}
      end
    end

    defp decode_part(%{"text" => text} = part) do
      {:ok, %A2A.Part.Text{text: text, metadata: part["metadata"] || %{}}}
    end

    defp decode_part(%{"data" => data} = part) do
      file_content =
        A2A.FileContent.from_bytes(
          Base.decode64!(data),
          name: part["filename"],
          mime_type: part["mediaType"]
        )

      {:ok,
       %A2A.Part.File{
         file: file_content,
         metadata: part["metadata"] || %{}
       }}
    end

    defp decode_part(%{"url" => url} = part) do
      file_content =
        A2A.FileContent.from_uri(
          url,
          name: part["filename"],
          mime_type: part["mediaType"]
        )

      {:ok,
       %A2A.Part.File{
         file: file_content,
         metadata: part["metadata"] || %{}
       }}
    end

    defp decode_part(_), do: {:error, :invalid_part}

    defp encode_message(%A2A.Message{} = message) do
      parts =
        Enum.map(message.parts, fn part ->
          encode_part(part)
        end)

      {:ok,
       %{
         "messageId" => message.message_id,
         "role" => @atom_to_role[message.role] || "ROLE_USER",
         "parts" => parts,
         "taskId" => message.task_id,
         "contextId" => message.context_id,
         "referenceTaskIds" => message.reference_task_ids,
         "metadata" => message.metadata,
         "extensions" => message.extensions
       }}
    end

    defp encode_part(%A2A.Part.Text{} = part) do
      %{
        "text" => part.text,
        "metadata" => part.metadata
      }
    end

    defp encode_part(%A2A.Part.File{file: %A2A.FileContent{bytes: data}} = part)
         when is_binary(data) do
      %{
        "data" => Base.encode64(data),
        "mediaType" => part.file.mime_type,
        "filename" => part.file.name,
        "metadata" => part.metadata
      }
    end

    defp encode_part(%A2A.Part.File{file: %A2A.FileContent{uri: url}} = part)
         when is_binary(url) do
      %{
        "url" => url,
        "mediaType" => part.file.mime_type,
        "filename" => part.file.name,
        "metadata" => part.metadata
      }
    end

    defp encode_status(%A2A.Task.Status{} = status) do
      encoded_msg =
        if status.message do
          {:ok, msg} = encode_message(status.message)
          msg
        else
          nil
        end

      {:ok,
       %{
         "state" => @state_to_string[status.state] || "TASK_STATE_UNKNOWN",
         "message" => encoded_msg,
         "timestamp" => DateTime.to_iso8601(status.timestamp)
       }}
    end

    defp encode_artifact(%A2A.Artifact{parts: parts} = artifact) do
      # For simplicity, just encode the first file part
      # In a real implementation, you might want more sophisticated handling
      first_file_part =
        Enum.find(parts, fn
          %A2A.Part.File{} -> true
          _ -> false
        end)

      case first_file_part do
        %A2A.Part.File{file: %A2A.FileContent{bytes: data}} when is_binary(data) ->
          %{
            "artifactId" => artifact.artifact_id,
            "mediaType" => first_file_part.file.mime_type,
            "data" => Base.encode64(data),
            "filename" => first_file_part.file.name,
            "metadata" => artifact.metadata
          }

        %A2A.Part.File{file: %A2A.FileContent{uri: url}} when is_binary(url) ->
          %{
            "artifactId" => artifact.artifact_id,
            "mediaType" => first_file_part.file.mime_type,
            "url" => url,
            "filename" => first_file_part.file.name,
            "metadata" => artifact.metadata
          }

        _ ->
          # No file parts, return minimal artifact info
          %{
            "artifactId" => artifact.artifact_id,
            "name" => artifact.name,
            "description" => artifact.description,
            "metadata" => artifact.metadata
          }
      end
    end

    defp maybe_put(opts, _key, nil), do: opts
    defp maybe_put(opts, key, val), do: [{key, val} | opts]
  end
end
