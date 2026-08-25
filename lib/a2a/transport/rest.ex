defmodule A2A.Transport.REST do
  @moduledoc """
  REST transport implementation for A2A protocol.

  Provides REST/HTTP-JSON transport for A2A agents. The server routes
  all requests through `A2A.JSONRPC` dispatch so the extension pipeline
  and authorization callbacks are applied consistently.
  """

  @doc """
  Returns true if REST transport dependencies are available.
  """
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(Req) and Code.ensure_loaded?(Plug)
  end
end
