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

  @valid_statuses ~w(
    TASK_STATE_SUBMITTED TASK_STATE_WORKING TASK_STATE_INPUT_REQUIRED
    TASK_STATE_COMPLETED TASK_STATE_CANCELED TASK_STATE_FAILED
    TASK_STATE_REJECTED TASK_STATE_AUTH_REQUIRED TASK_STATE_UNKNOWN
  )

  def validate_params(%__MODULE__{method: "tasks/list", params: params}) do
    cond do
      bad_page_size?(params) ->
        {:error, Error.invalid_params("\"pageSize\" must be an integer between 1 and 100")}

      bad_status?(params) ->
        {:error, Error.invalid_params("\"status\" must be a valid task state")}

      bad_history_length?(params) ->
        {:error, Error.invalid_params("\"historyLength\" must be a non-negative integer")}

      bad_timestamp?(params) ->
        {:error,
         Error.invalid_params("\"statusTimestampAfter\" must be a valid ISO 8601 timestamp")}

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

  defp bad_page_size?(%{"pageSize" => ps}) do
    not is_integer(ps) or ps < 1 or ps > 100
  end

  defp bad_page_size?(_), do: false

  defp bad_status?(%{"status" => status}) when is_binary(status) do
    status not in @valid_statuses
  end

  defp bad_status?(%{"status" => _}), do: true
  defp bad_status?(_), do: false

  defp bad_history_length?(%{"historyLength" => hl}) do
    not is_integer(hl) or hl < 0
  end

  defp bad_history_length?(_), do: false

  defp bad_timestamp?(%{"statusTimestampAfter" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, _, _} -> false
      _ -> true
    end
  end

  defp bad_timestamp?(%{"statusTimestampAfter" => _}), do: true
  defp bad_timestamp?(_), do: false
end
