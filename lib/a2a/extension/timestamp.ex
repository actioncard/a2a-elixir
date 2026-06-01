defmodule A2A.Extension.Timestamp do
  @moduledoc """
  Reference `A2A.Extension` that timestamps requests and responses.

  Stamps `Message.metadata` on the way in and `Task.metadata` on the way
  out under the extension's URI:

      "https://a2a-protocol.org/extensions/timestamp/v1" => %{
        received_at: 1_700_000_000_000,
        completed_at: 1_700_000_000_042
      }

  Times are wall-clock milliseconds via `System.system_time(:millisecond)`.

  ## Usage

  Configure on the server and (optionally) on the client. Both must declare
  the URI for the activation to round-trip.

      # Server
      Bandit.start_link(
        plug: {A2A.Plug,
          agent: MyAgent,
          base_url: "http://localhost:4000",
          extensions: [A2A.Extension.Timestamp]}
      )

      # Client
      client = A2A.Client.new("http://localhost:4000",
        extensions: [A2A.Extension.Timestamp])

      {:ok, task} = A2A.Client.send_message(client, "hi")
      task.metadata["https://a2a-protocol.org/extensions/timestamp/v1"]
      #=> %{"received_at" => 1700000000000, "completed_at" => 1700000000042}

  Map keys are atoms on the server (before encoding) and strings on the
  client (after JSON decode).

  ## What this exercises

  This module implements every optional callback of `A2A.Extension`:

    * `c:A2A.Extension.declaration/1` — non-required profile extension.
    * `c:A2A.Extension.activate/3` — captures the per-request start time.
    * `c:A2A.Extension.handle_request/3` — stamps the inbound message metadata.
    * `c:A2A.Extension.handle_response/3` — stamps the outbound task metadata.

  Copy it as a starting template for your own profile-style extension.
  """

  @behaviour A2A.Extension

  @uri "https://a2a-protocol.org/extensions/timestamp/v1"

  @typedoc """
  Activation state: the wall-clock millisecond when the request was first
  observed by the server.
  """
  @type activation :: %{received_at: integer()}

  @doc "The stable URI advertised by this extension."
  @spec uri() :: String.t()
  def uri, do: @uri

  @impl A2A.Extension
  def declaration(_state) do
    %A2A.AgentExtension{
      uri: @uri,
      description: "Stamps requests and responses with wall-clock milliseconds."
    }
  end

  @impl A2A.Extension
  def activate(_requested, _ctx, _state) do
    {:ok, %{received_at: System.system_time(:millisecond)}}
  end

  @impl A2A.Extension
  def handle_request(message, params, %{received_at: t} = activation) do
    message = A2A.Extension.put_metadata(message, __MODULE__, %{received_at: t})
    {:ok, message, params, activation}
  end

  @impl A2A.Extension
  def handle_response(task, _params, %{received_at: t} = activation) do
    stamp = %{received_at: t, completed_at: System.system_time(:millisecond)}
    {:ok, A2A.Extension.put_metadata(task, __MODULE__, stamp), activation}
  end
end
