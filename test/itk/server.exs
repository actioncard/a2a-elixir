# Boots a Bandit server exposing the test-harness ITK Elixir agent over A2A
# JSON-RPC, shaped so the Python A2A ITK runner (a2a-samples/itk) can drive it.
#
# Usage:
#   mix run test/itk/server.exs --httpPort 10110
#   A2A_ITK_HTTP_PORT=10110 mix run test/itk/server.exs
#
# Mirrors test/tck/server.exs, but:
#   * Serves a v0.3-shaped Agent Card (preferredTransport / additionalInterfaces /
#     url ending in /jsonrpc/) at /jsonrpc/.well-known/agent-card.json. The Elixir
#     SDK's own card encoder emits the v1.0-style `supportedInterfaces` field which
#     the Python v0.3 ClientFactory does not understand, so we hand-build the v0.3
#     card here (test-harness-only; lib/ is untouched). This card-shape difference
#     is part of the documented v0.3-vs-v1.0 axis (see docs/ITK_BASELINE.md).
#   * Routes JSON-RPC POSTs through A2A.JSONRPC.handle/3 with the test-harness
#     handler A2A.Test.ITK.Agent, which decodes the ITK Instruction proto and
#     returns a completed task whose status.message carries the response text.
#
# --grpcPort is accepted and ignored (gRPC is intentionally out of scope).
#
# IMPORTANT: run this under MIX_ENV=test so the harness support modules
# (A2A.Test.ITK.Instruction / .Agent under test/support/) are compiled and
# available — they are only on elixirc_paths in :test (see mix.exs). The ITK
# harness launcher sets MIX_ENV=test:
#   MIX_ENV=test mix run test/itk/server.exs --httpPort 10110
if Code.ensure_loaded?(A2A.Test.ITK.Agent) == false do
  IO.puts(:stderr, "FATAL: A2A.Test.ITK.Agent not loaded — run with MIX_ENV=test")
  System.halt(1)
end

defmodule A2A.Test.ITK.CardAgent do
  @moduledoc false
  # Minimal GenServer agent; only used so a real A2A agent identity exists.
  # The actual JSON-RPC handling is done by A2A.Test.ITK.Agent.
  use A2A.Agent,
    name: "itk-elixir-v03-agent",
    description: "A2A Elixir ITK agent (JSON-RPC only)",
    version: "0.3.0",
    skills: [
      %{
        id: "itk_proto_skill",
        name: "ITK Proto Skill",
        description: "Handles raw byte Instruction protos over JSON-RPC.",
        tags: ["proto", "itk", "jsonrpc"]
      }
    ]

  @impl A2A.Agent
  def handle_message(_message, _context) do
    {:reply, [A2A.Part.Text.new("itk-elixir-agent")]}
  end

  @impl A2A.Agent
  def handle_cancel(_context), do: :ok
end

defmodule A2A.Test.ITK.Router do
  @moduledoc false
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  # v0.3-shaped agent card. The Python v0.3 ClientFactory fetches this relative
  # to the agent_card_uri (".../jsonrpc/.well-known/agent-card.json").
  defp agent_card_json do
    host = Application.get_env(:a2a_itk, :host)
    port = Application.get_env(:a2a_itk, :http_port)
    grpc_port = Application.get_env(:a2a_itk, :grpc_port)

    %{
      "name" => "ITK Elixir v03 Agent",
      "description" => "A2A Elixir SDK agent for ITK conformance (JSON-RPC only).",
      "url" => "http://#{host}:#{port}/jsonrpc/",
      "version" => "0.3.0",
      "protocolVersion" => "0.3.0",
      "preferredTransport" => "JSONRPC",
      "defaultInputModes" => ["text"],
      "defaultOutputModes" => ["text"],
      "capabilities" => %{"streaming" => true},
      "skills" => [
        %{
          "id" => "itk_proto_skill",
          "name" => "ITK Proto Skill",
          "description" => "Handles raw byte Instruction protos over JSON-RPC.",
          "tags" => ["proto", "itk", "jsonrpc"]
        }
      ],
      # gRPC interface advertised for card-shape parity with the python_v03 card,
      # but the Elixir agent does NOT serve gRPC. Traversals must use jsonrpc.
      "additionalInterfaces" => [
        %{"transport" => "GRPC", "url" => "#{host}:#{grpc_port}"}
      ]
    }
  end

  # Native v1.0-style card emitted by the SDK's own encoder
  # (A2A.JSON.encode_agent_card). This produces the `supportedInterfaces`
  # shape and OMITS `preferredTransport`/`additionalInterfaces`. Used only to
  # demonstrate the documented v0.3-vs-v1.0 card-shape gap (see
  # docs/ITK_BASELINE.md). Selected via `--cardVersion v1`.
  defp agent_card_v10_json do
    host = Application.get_env(:a2a_itk, :host)
    port = Application.get_env(:a2a_itk, :http_port)

    A2A.get_agent_card(A2A.Test.ITK.CardAgent,
      base_url: "http://#{host}:#{port}/jsonrpc/",
      capabilities: %{streaming: true},
      default_input_modes: ["text"],
      default_output_modes: ["text"],
      protocol_version: "0.3.0"
    )
  end

  defp send_card(conn) do
    card =
      case Application.get_env(:a2a_itk, :card_version) do
        "v1" -> agent_card_v10_json()
        _ -> agent_card_json()
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(card))
  end

  defp handle_rpc(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

    case Jason.decode(body) do
      {:ok, decoded} ->
        case A2A.JSONRPC.handle(decoded, A2A.Test.ITK.Agent, %{}) do
          {:reply, response} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(response))

          {:stream, _method, params, id} ->
            # The ITK Python client's `send_message` uses the streaming method
            # (message/stream) as its PRIMARY path and REQUIRES a
            # `text/event-stream` (SSE) response. We compute the result via the
            # same handler used for message/send, then emit it as SSE: a Task
            # snapshot event followed by a final StatusUpdate event (final:true).
            # This mirrors A2A.Plug.SSE's wire format without requiring the agent
            # to implement A2A.stream/3.
            stream_send_as_sse(conn, params, id)
        end

      {:error, _} ->
        send_resp(conn, 400, "invalid json")
    end
  end

  # Emit a non-streaming handler result as an SSE stream so the ITK Python
  # client (which calls message/stream and expects text/event-stream) is
  # satisfied. Events mirror A2A.Plug.SSE: each `data:` line wraps a JSON-RPC
  # success envelope around an encoded A2A object. We send the completed Task
  # snapshot, then a final StatusUpdate (final: true).
  defp stream_send_as_sse(conn, params, id) do
    # A2A.JSONRPC.handle pre-decodes params["message"] into an %A2A.Message{}
    # struct before emitting the {:stream, ...} tuple (see A2A.Plug usage), so
    # we use it directly rather than re-decoding.
    message = params["message"]

    case A2A.Test.ITK.Agent.handle_send(message, params, %{}) do
      {:ok, %A2A.Task{} = task} ->
        conn =
          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> send_chunked(200)

        {:ok, task_encoded} = A2A.JSON.encode(task)
        conn = sse_event(conn, id, task_encoded)

        final =
          A2A.Event.StatusUpdate.new(
            task.id,
            A2A.Task.Status.new(:completed, task.status.message),
            context_id: task.context_id,
            final: true
          )

        {:ok, final_encoded} = A2A.JSON.encode(final)
        sse_event(conn, id, final_encoded)

      {:error, error} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "error" => error}))
    end
  end

  defp sse_event(conn, id, encoded_result) do
    payload = %{"jsonrpc" => "2.0", "id" => id, "result" => encoded_result}

    case chunk(conn, "data: #{Jason.encode!(payload)}\n\n") do
      {:ok, conn} -> conn
      {:error, :closed} -> conn
    end
  end

  # Card at both the /jsonrpc-mounted path and the bare well-known path.
  get("/jsonrpc/.well-known/agent-card.json", do: send_card(conn))
  get("/.well-known/agent-card.json", do: send_card(conn))

  # JSON-RPC endpoint. Plug normalizes the trailing slash, so a single route
  # matches both /jsonrpc and /jsonrpc/.
  post("/jsonrpc", do: handle_rpc(conn))

  match _ do
    send_resp(conn, 404, "not found")
  end
end

# --- argument / env parsing -------------------------------------------------

{parsed, _rest, _invalid} =
  OptionParser.parse(System.argv(),
    strict: [httpPort: :integer, grpcPort: :integer, cardVersion: :string],
    aliases: []
  )

http_port =
  parsed[:httpPort] ||
    (System.get_env("A2A_ITK_HTTP_PORT") && String.to_integer(System.get_env("A2A_ITK_HTTP_PORT"))) ||
    10_110

grpc_port =
  parsed[:grpcPort] ||
    (System.get_env("A2A_ITK_GRPC_PORT") && String.to_integer(System.get_env("A2A_ITK_GRPC_PORT"))) ||
    11_110

host = System.get_env("A2A_ITK_HOST") || "127.0.0.1"

card_version = parsed[:cardVersion] || System.get_env("A2A_ITK_CARD_VERSION") || "v03"

Application.put_env(:a2a_itk, :host, host)
Application.put_env(:a2a_itk, :http_port, http_port)
Application.put_env(:a2a_itk, :grpc_port, grpc_port)
Application.put_env(:a2a_itk, :card_version, card_version)

{:ok, _} = A2A.Test.ITK.CardAgent.start_link()

{:ok, _} =
  Bandit.start_link(
    plug: A2A.Test.ITK.Router,
    port: http_port,
    ip: {127, 0, 0, 1},
    startup_log: false
  )

IO.puts("ITK Elixir agent running on http://#{host}:#{http_port}/jsonrpc")
IO.puts("Agent card: http://#{host}:#{http_port}/jsonrpc/.well-known/agent-card.json")
IO.puts("(gRPC port #{grpc_port} advertised but NOT served — JSON-RPC only)")

Process.sleep(:infinity)
