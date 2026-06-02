defmodule A2A.Test.ITK.Agent do
  @moduledoc """
  Test-harness-only A2A agent that participates in the A2A Interoperability
  Test Kit (ITK).

  This module is **not** part of the shipped library — it lives under `test/`
  (mirroring `test/tck/`) and exists solely so a JSON-RPC-only Elixir agent can
  be driven by the Python ITK runner (`a2a-samples/itk`).

  ## What it does

  The ITK runner wraps a serialized `itk.Instruction` protobuf inside an A2A
  `FilePart` (`mime_type: application/x-protobuf`, `name: instruction.bin`) and
  dispatches it over JSON-RPC `message/send`. This agent:

  1. Extracts the FilePart bytes from the incoming `%A2A.Message{}`.
  2. Decodes them with `A2A.Test.ITK.Instruction.decode/1`.
  3. Recursively interprets the instruction:
     - `{:return_response, text}` → returns `text`.
     - `{:steps, instructions, gen}` → interprets each in order and concatenates
       the resulting text fragments (the only response generator ITK uses is
       `CONCAT`).
     - `{:call_agent, %{...}}` → calls the downstream agent over JSON-RPC using
       `A2A.Client.send_message/3` (or `stream_message/3` when `streaming` is
       set), then extracts the text from the downstream response.

  The accumulated text is returned as a completed `%A2A.Task{}` whose
  `status.message` holds the text. This matches the Python v0.3 ITK agent, whose
  `task_updater.complete(message=...)` populates `status.message` — which is the
  field the ITK runner (`testlib.execute_itk_test`) reads to verify traversal
  tokens.

  ## Why a custom JSON-RPC handler (not `use A2A.Agent`)

  `use A2A.Agent` maps a `{:reply, parts}` result to an **artifact** plus a
  `:completed` status, but it does *not* set `status.message`. The ITK runner
  only reads `Message` responses and `task.status.message` text, so we build the
  completed task directly here, setting `status.message`. We still wire this
  module as an `A2A.JSONRPC` handler so the SDK's own JSON-RPC dispatch and JSON
  codec do the envelope/serialization work.

  Transport scope: JSON-RPC only. gRPC/REST hops are out of scope (see
  `docs/ITK_BASELINE.md`); a `CallAgent` requesting a non-JSON-RPC transport is
  reported as an error fragment rather than silently mis-handled.
  """

  @behaviour A2A.JSONRPC

  alias A2A.JSONRPC.Error
  alias A2A.Test.ITK.Instruction

  @typedoc "Options threaded into the handler context by the server."
  @type context :: map()

  # ---------------------------------------------------------------------------
  # A2A.JSONRPC behaviour
  # ---------------------------------------------------------------------------

  @impl A2A.JSONRPC
  @spec handle_send(A2A.Message.t(), map(), context()) ::
          {:ok, A2A.Task.t()} | {:error, Error.t()}
  def handle_send(%A2A.Message{} = message, params, _context) do
    with {:ok, bytes} <- extract_instruction_bytes(message),
         {:ok, instruction} <- Instruction.decode(bytes) do
      text = interpret(instruction)

      task =
        completed_task(
          message.task_id || A2A.ID.generate("task"),
          message.context_id || params["contextId"] || A2A.ID.generate("ctx"),
          text
        )

      {:ok, task}
    else
      {:error, reason} ->
        {:error, Error.invalid_params("ITK instruction handling failed: #{inspect(reason)}")}
    end
  end

  @impl A2A.JSONRPC
  @spec handle_get(String.t(), map(), context()) :: {:ok, A2A.Task.t()} | {:error, Error.t()}
  def handle_get(task_id, _params, _context) do
    # The ITK runner does not call tasks/get; return a not-found error.
    {:error, Error.task_not_found(task_id)}
  end

  @impl A2A.JSONRPC
  @spec handle_cancel(String.t(), map(), context()) :: {:ok, A2A.Task.t()} | {:error, Error.t()}
  def handle_cancel(task_id, _params, _context) do
    {:error, Error.task_not_found(task_id)}
  end

  # ---------------------------------------------------------------------------
  # Instruction interpretation
  # ---------------------------------------------------------------------------

  @doc """
  Recursively interprets a decoded ITK instruction into a response string.

  Exposed for unit testing. `call_agent` hops use `call_downstream/1` by
  default; pass a 1-arity function as the second argument to stub downstream
  calls in tests.
  """
  @spec interpret(Instruction.instruction(), (Instruction.call_agent() -> String.t())) ::
          String.t()
  def interpret(instruction, call_fun \\ &call_downstream/1)

  def interpret({:return_response, text}, _call_fun), do: text

  def interpret({:steps, instructions, _generator}, call_fun) do
    # ITK only ever uses RESPONSE_GENERATOR_CONCAT (or unspecified, treated the
    # same): interpret each step in order and concatenate the fragments.
    instructions
    |> Enum.map(&interpret(&1, call_fun))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def interpret({:call_agent, call_agent}, call_fun) do
    call_fun.(call_agent)
  end

  # ---------------------------------------------------------------------------
  # Downstream call (JSON-RPC only)
  # ---------------------------------------------------------------------------

  @doc """
  Calls a downstream agent for a `CallAgent` step and returns its text.

  Only the `jsonrpc` transport is supported. Other transports yield an error
  fragment so the failure is visible in the traversal output rather than silent.
  """
  @spec call_downstream(Instruction.call_agent()) :: String.t()
  def call_downstream(%{transport: transport} = call)
      when transport in ["jsonrpc", "JSONRPC", "", nil] do
    message = wrap_instruction(call.instruction)
    target = card_base_url(call.agent_card_uri)

    if call.streaming do
      call_downstream_stream(target, message, call.agent_card_uri)
    else
      call_downstream_send(target, message, call.agent_card_uri)
    end
  end

  def call_downstream(%{transport: transport, agent_card_uri: uri}) do
    "ERROR: unsupported transport #{inspect(transport)} for #{uri} (JSON-RPC only)"
  end

  defp call_downstream_send(target, message, uri) do
    case A2A.Client.send_message(target, message) do
      {:ok, %A2A.Task{} = task} -> task_text(task)
      {:error, reason} -> "ERROR: call to #{uri} failed: #{inspect(reason)}"
    end
  end

  defp call_downstream_stream(target, message, uri) do
    case A2A.Client.stream_message(target, message) do
      {:ok, stream} ->
        stream
        |> Enum.flat_map(&event_text/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      {:error, reason} ->
        "ERROR: stream call to #{uri} failed: #{inspect(reason)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Text extraction helpers
  # ---------------------------------------------------------------------------

  # Pulls text out of a downstream task: prefer status.message, fall back to
  # the most recent artifact / agent history message.
  defp task_text(%A2A.Task{status: %A2A.Task.Status{message: %A2A.Message{} = msg}}) do
    message_text(msg)
  end

  defp task_text(%A2A.Task{artifacts: [_ | _] = artifacts}) do
    artifacts
    |> List.last()
    |> Map.get(:parts, [])
    |> parts_text()
  end

  defp task_text(%A2A.Task{history: history}) when is_list(history) and history != [] do
    history
    |> Enum.reverse()
    |> Enum.find(&(&1.role == :agent))
    |> case do
      nil -> ""
      msg -> message_text(msg)
    end
  end

  defp task_text(_), do: ""

  defp event_text(%A2A.Message{} = msg), do: [message_text(msg)]

  defp event_text(%A2A.Event.StatusUpdate{status: %A2A.Task.Status{message: %A2A.Message{} = m}}) do
    [message_text(m)]
  end

  defp event_text(%A2A.Event.ArtifactUpdate{artifact: %A2A.Artifact{parts: parts}}) do
    [parts_text(parts)]
  end

  defp event_text(%A2A.Task{} = task), do: [task_text(task)]
  defp event_text(_), do: [""]

  defp message_text(%A2A.Message{parts: parts}), do: parts_text(parts)

  defp parts_text(parts) do
    parts
    |> Enum.map(fn
      %A2A.Part.Text{text: text} -> text
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # ---------------------------------------------------------------------------
  # Message / task construction
  # ---------------------------------------------------------------------------

  defp extract_instruction_bytes(%A2A.Message{parts: parts}) do
    parts
    |> Enum.find_value(fn
      %A2A.Part.File{file: %A2A.FileContent{bytes: bytes}} when is_binary(bytes) -> bytes
      _ -> nil
    end)
    |> case do
      nil -> {:error, :no_instruction_file_part}
      bytes -> {:ok, bytes}
    end
  end

  # Wraps a nested instruction back into an A2A message (FilePart) for the
  # downstream hop, mirroring the ITK runner's `_wrap_instruction`.
  defp wrap_instruction(instruction) do
    bytes = Instruction.encode(instruction)

    file =
      A2A.FileContent.from_bytes(bytes,
        name: "instruction.bin",
        mime_type: "application/x-protobuf"
      )

    A2A.Message.new_user([A2A.Part.File.new(file)])
  end

  defp completed_task(task_id, context_id, text) do
    status_message = A2A.Message.new_agent([A2A.Part.Text.new(text)])

    %A2A.Task{
      id: task_id,
      context_id: context_id,
      status: A2A.Task.Status.new(:completed, status_message),
      history: [],
      artifacts: [A2A.Artifact.new([A2A.Part.Text.new(text)])],
      metadata: %{}
    }
  end

  # The ITK runner connects to `http://host:port/jsonrpc` and the JSON-RPC POST
  # endpoint is served at `/jsonrpc/` — strip a trailing slash for the client.
  defp card_base_url(uri), do: String.trim_trailing(uri, "/")
end
