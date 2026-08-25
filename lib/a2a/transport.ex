defmodule A2A.Transport do
  @moduledoc """
  Multi-transport support for A2A protocol.

  Currently supports:

  - **JSON-RPC 2.0** (via HTTP) — Default transport in `A2A.Plug` and `A2A.Client`
  - **REST/HTTP-JSON** — Direct HTTP endpoints via `A2A.Transport.REST`
  """

  @doc """
  Returns a list of available transport protocols.
  """
  @spec available_transports() :: [atom()]
  def available_transports do
    transports = [:jsonrpc]

    if A2A.Transport.REST.available?() do
      transports ++ [:rest]
    else
      transports
    end
  end

  @doc """
  Checks if a specific transport is available.
  """
  @spec available?(atom()) :: boolean()
  def available?(:jsonrpc), do: true
  def available?(:rest), do: A2A.Transport.REST.available?()
  def available?(_), do: false
end
