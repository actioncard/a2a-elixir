defmodule A2A.JSONRPC.Request do
  @moduledoc false

  alias A2A.JSONRPC.Error

  @type id :: String.t() | integer() | nil

  @type t :: %__MODULE__{
          jsonrpc: String.t(),
          id: id(),
          method: String.t(),
          params: map()
        }

  @enforce_keys [:jsonrpc, :method]
  defstruct [:jsonrpc, :id, :method, params: %{}]

  @doc """
  Parses a raw map into a `%Request{}`, validating the JSON-RPC 2.0 envelope.

  Returns `{:ok, request}` or `{:error, %Error{}}`.
  """
  @spec parse(map()) :: {:ok, t()} | {:error, Error.t()}
  def parse(%{} = raw) do
    with :ok <- validate_jsonrpc(raw),
         {:ok, method} <- validate_method(raw),
         {:ok, id} <- validate_id(raw),
         {:ok, params} <- validate_params_field(raw) do
      {:ok, %__MODULE__{jsonrpc: "2.0", id: id, method: method, params: params}}
    end
  end

  def parse(_), do: {:error, Error.invalid_request("Request must be a JSON object")}

  @doc """
  Validates method-specific params on a parsed request.

  Returns `:ok` or `{:error, %Error{}}`.
  """
  @spec validate_params(t()) :: :ok | {:error, Error.t()}
  def validate_params(%__MODULE__{method: method, params: params})
      when method in ["message/send", "message/stream"] do
    if is_map(params["message"]) do
      :ok
    else
      {:error, Error.invalid_params("\"message\" must be a JSON object")}
    end
  end

  def validate_params(%__MODULE__{method: method, params: params})
      when method in ["tasks/get", "tasks/cancel", "tasks/resubscribe"] do
    if is_binary(params["id"]) do
      :ok
    else
      {:error, Error.invalid_params("\"id\" must be a string")}
    end
  end

  def validate_params(%__MODULE__{method: "tasks/list", params: params}) do
    cond do
      not is_nil(params["pageSize"]) and
          (not is_integer(params["pageSize"]) or params["pageSize"] < 1 or
             params["pageSize"] > 100) ->
        {:error, Error.invalid_params("\"pageSize\" must be an integer between 1 and 100")}

      true ->
        :ok
    end
  end

  def validate_params(%__MODULE__{}), do: :ok

  # -- private ---------------------------------------------------------------

  defp validate_jsonrpc(%{"jsonrpc" => "2.0"}), do: :ok

  defp validate_jsonrpc(_) do
    {:error, Error.invalid_request("\"jsonrpc\" must be \"2.0\"")}
  end

  defp validate_method(%{"method" => method}) when is_binary(method), do: {:ok, method}

  defp validate_method(_) do
    {:error, Error.invalid_request("\"method\" must be a string")}
  end

  defp validate_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
  defp validate_id(%{"id" => id}) when is_integer(id), do: {:ok, id}
  defp validate_id(%{"id" => nil}), do: {:ok, nil}
  defp validate_id(raw) when not is_map_key(raw, "id"), do: {:ok, nil}

  defp validate_id(_) do
    {:error, Error.invalid_request("\"id\" must be a string, integer, or null")}
  end

  defp validate_params_field(%{"params" => params}) when is_map(params), do: {:ok, params}
  defp validate_params_field(%{"params" => _}), do: {:ok, %{}}
  defp validate_params_field(_), do: {:ok, %{}}
end
