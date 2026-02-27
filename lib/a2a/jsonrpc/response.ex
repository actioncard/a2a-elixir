defmodule A2A.JSONRPC.Response do
  @moduledoc false

  alias A2A.JSONRPC.{Error, Request}

  @doc """
  Builds a JSON-RPC 2.0 success response envelope.
  """
  @spec success(Request.id(), map()) :: map()
  def success(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  @doc """
  Builds a JSON-RPC 2.0 error response envelope.
  """
  @spec error(Request.id(), Error.t()) :: map()
  def error(id, %Error{} = error) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => Error.to_map(error)}
  end
end
