defmodule A2A.Test.ITK.Instruction do
  @moduledoc """
  Hand-rolled proto3 codec for the A2A ITK `itk.Instruction` payload.

  This is **test-harness-only** code (it lives under `test/support/`, not `lib/`),
  mirroring the `test/tck/` pattern. It exists solely so a JSON-RPC-only Elixir
  agent can participate in the A2A Interoperability Test Kit (ITK), whose agents
  exchange a serialized protobuf `Instruction` carried as a FilePart.

  The wire schema (from `a2a-samples/itk/protos/instruction.proto`):

      message Instruction {
        oneof step {
          CallAgent call_agent = 1;
          ReturnResponse return_response = 2;
          SeriesOfSteps steps = 3;
        }
      }
      message CallAgent {
        string transport = 1;
        string agent_card_uri = 2;
        Instruction instruction = 3;
        bool streaming = 4;
      }
      message ReturnResponse { string response = 1; }
      message SeriesOfSteps {
        repeated Instruction instructions = 1;
        enum ResponseGenerator {
          RESPONSE_GENERATOR_UNSPECIFIED = 0;
          RESPONSE_GENERATOR_CONCAT = 1;
        }
        ResponseGenerator response_generator = 2;
      }

  No external protobuf dependency is used. We implement the minimal proto3 wire
  format (varints + length-delimited fields) needed for these four messages.

  Decoded instructions are represented as tagged tuples:

  - `{:return_response, binary}`
  - `{:steps, [instruction], response_generator :: 0 | 1}`
  - `{:call_agent, %{transport: binary, agent_card_uri: binary,
      instruction: instruction | nil, streaming: boolean}}`
  """

  @type response_generator :: 0 | 1

  @type call_agent :: %{
          transport: binary(),
          agent_card_uri: binary(),
          instruction: instruction() | nil,
          streaming: boolean()
        }

  @type instruction ::
          {:return_response, binary()}
          | {:steps, [instruction()], response_generator()}
          | {:call_agent, call_agent()}

  # ---------------------------------------------------------------------------
  # Decoding
  # ---------------------------------------------------------------------------

  @doc """
  Decodes a serialized `itk.Instruction` protobuf into a tagged tuple.

  Returns `{:ok, instruction}` or `{:error, reason}`.
  """
  @spec decode(binary()) :: {:ok, instruction()} | {:error, term()}
  def decode(bin) when is_binary(bin) do
    {:ok, decode_instruction(bin)}
  rescue
    e -> {:error, {:decode_failed, Exception.message(e)}}
  end

  @doc """
  Like `decode/1` but raises on failure. Convenient for tests.
  """
  @spec decode!(binary()) :: instruction()
  def decode!(bin) do
    case decode(bin) do
      {:ok, inst} -> inst
      {:error, reason} -> raise "ITK instruction decode failed: #{inspect(reason)}"
    end
  end

  # An Instruction is a oneof over fields 1 (call_agent), 2 (return_response),
  # 3 (steps). The last one wins if (illegally) repeated.
  defp decode_instruction(bin) do
    bin
    |> decode_fields()
    |> Enum.reduce(nil, fn
      {1, {:length_delimited, data}}, _acc -> {:call_agent, decode_call_agent(data)}
      {2, {:length_delimited, data}}, _acc -> {:return_response, decode_return_response(data)}
      {3, {:length_delimited, data}}, _acc -> decode_steps(data)
      _other, acc -> acc
    end)
  end

  defp decode_return_response(bin) do
    bin
    |> decode_fields()
    |> Enum.reduce("", fn
      {1, {:length_delimited, data}}, _acc -> data
      _other, acc -> acc
    end)
  end

  defp decode_steps(bin) do
    {instructions_rev, gen} =
      bin
      |> decode_fields()
      |> Enum.reduce({[], 0}, fn
        {1, {:length_delimited, data}}, {acc, gen} ->
          {[decode_instruction(data) | acc], gen}

        {2, {:varint, v}}, {acc, _gen} ->
          {acc, v}

        _other, acc_gen ->
          acc_gen
      end)

    {:steps, Enum.reverse(instructions_rev), gen}
  end

  defp decode_call_agent(bin) do
    bin
    |> decode_fields()
    |> Enum.reduce(
      %{transport: "", agent_card_uri: "", instruction: nil, streaming: false},
      fn
        {1, {:length_delimited, data}}, acc -> %{acc | transport: data}
        {2, {:length_delimited, data}}, acc -> %{acc | agent_card_uri: data}
        {3, {:length_delimited, data}}, acc -> %{acc | instruction: decode_instruction(data)}
        {4, {:varint, v}}, acc -> %{acc | streaming: v != 0}
        _other, acc -> acc
      end
    )
  end

  # Decodes a flat list of {field_number, value} from a proto3 message body.
  defp decode_fields(<<>>), do: []

  defp decode_fields(bin) do
    {tag, rest} = decode_varint(bin)
    field_number = Bitwise.bsr(tag, 3)
    wire_type = Bitwise.band(tag, 0x7)

    case wire_type do
      0 ->
        {value, rest} = decode_varint(rest)
        [{field_number, {:varint, value}} | decode_fields(rest)]

      2 ->
        {len, rest} = decode_varint(rest)
        <<data::binary-size(len), rest::binary>> = rest
        [{field_number, {:length_delimited, data}} | decode_fields(rest)]

      1 ->
        <<_fixed64::binary-size(8), rest::binary>> = rest
        decode_fields(rest)

      5 ->
        <<_fixed32::binary-size(4), rest::binary>> = rest
        decode_fields(rest)

      other ->
        raise "unsupported proto wire type: #{other}"
    end
  end

  defp decode_varint(bin), do: decode_varint(bin, 0, 0)

  defp decode_varint(<<1::1, chunk::7, rest::binary>>, shift, acc) do
    decode_varint(rest, shift + 7, Bitwise.bor(acc, Bitwise.bsl(chunk, shift)))
  end

  defp decode_varint(<<0::1, chunk::7, rest::binary>>, shift, acc) do
    {Bitwise.bor(acc, Bitwise.bsl(chunk, shift)), rest}
  end

  # ---------------------------------------------------------------------------
  # Encoding (used by tests / fixtures; round-trips with decode/1)
  # ---------------------------------------------------------------------------

  @doc """
  Encodes a tagged-tuple instruction back into serialized proto3 bytes.
  """
  @spec encode(instruction()) :: binary()
  def encode({:return_response, response}) do
    encode_field(2, {:length_delimited, encode_return_response(response)})
  end

  def encode({:steps, instructions, gen}) do
    encode_field(3, {:length_delimited, encode_steps(instructions, gen)})
  end

  def encode({:call_agent, ca}) do
    encode_field(1, {:length_delimited, encode_call_agent(ca)})
  end

  defp encode_return_response(response) do
    encode_field(1, {:length_delimited, response})
  end

  defp encode_steps(instructions, gen) do
    body =
      instructions
      |> Enum.map(fn inst -> encode_field(1, {:length_delimited, encode(inst)}) end)
      |> IO.iodata_to_binary()

    gen_field = if gen == 0, do: <<>>, else: encode_field(2, {:varint, gen})
    body <> gen_field
  end

  defp encode_call_agent(ca) do
    [
      encode_str(1, ca.transport),
      encode_str(2, ca.agent_card_uri),
      case ca.instruction do
        nil -> <<>>
        inst -> encode_field(3, {:length_delimited, encode(inst)})
      end,
      if(ca.streaming, do: encode_field(4, {:varint, 1}), else: <<>>)
    ]
    |> IO.iodata_to_binary()
  end

  defp encode_str(_field, ""), do: <<>>
  defp encode_str(field, str), do: encode_field(field, {:length_delimited, str})

  defp encode_field(field_number, {:varint, value}) do
    tag = Bitwise.bor(Bitwise.bsl(field_number, 3), 0)
    encode_varint(tag) <> encode_varint(value)
  end

  defp encode_field(field_number, {:length_delimited, data}) do
    tag = Bitwise.bor(Bitwise.bsl(field_number, 3), 2)
    encode_varint(tag) <> encode_varint(byte_size(data)) <> data
  end

  defp encode_varint(value) when value < 0x80, do: <<value>>

  defp encode_varint(value) do
    <<1::1, Bitwise.band(value, 0x7F)::7>> <> encode_varint(Bitwise.bsr(value, 7))
  end
end
