defmodule A2A.JSONRPC.Error do
  @moduledoc """
  JSON-RPC 2.0 error with A2A-specific error codes.

  Provides a struct and named constructors for the 14 error codes defined by
  the A2A protocol (5 standard JSON-RPC + 9 A2A-specific).

  A2A-specific errors (-32001..-32009) serialize with a `google.rpc.ErrorInfo`
  object inside a `"data"` array, as the spec requires. The 5 standard JSON-RPC
  codes have no defined `reason` and keep their free-form `data`.

  ## Example

      iex> error = A2A.JSONRPC.Error.task_not_found()
      iex> error.code
      -32001
      iex> A2A.JSONRPC.Error.to_map(error)
      %{
        "code" => -32001,
        "message" => "Task not found",
        "data" => [
          %{
            "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
            "domain" => "a2a-protocol.org",
            "reason" => "TASK_NOT_FOUND"
          }
        ]
      }
  """

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: term()
        }

  @enforce_keys [:code, :message]
  defstruct [:code, :message, :data]

  @error_info_type "type.googleapis.com/google.rpc.ErrorInfo"
  @a2a_domain "a2a-protocol.org"

  # Reason strings are keyed by code, not by constructor name: -32007's reason
  # is EXTENDED_AGENT_CARD_NOT_CONFIGURED while its constructor is
  # authenticated_extended_card_not_configured/1.
  @a2a_reasons %{
    -32_001 => "TASK_NOT_FOUND",
    -32_002 => "TASK_NOT_CANCELABLE",
    -32_003 => "PUSH_NOTIFICATION_NOT_SUPPORTED",
    -32_004 => "UNSUPPORTED_OPERATION",
    -32_005 => "CONTENT_TYPE_NOT_SUPPORTED",
    -32_006 => "INVALID_AGENT_RESPONSE",
    -32_007 => "EXTENDED_AGENT_CARD_NOT_CONFIGURED",
    -32_008 => "EXTENSION_SUPPORT_REQUIRED",
    -32_009 => "VERSION_NOT_SUPPORTED"
  }

  @doc "Builds a parse error (-32700)."
  @spec parse_error(term()) :: t()
  def parse_error(data \\ nil) do
    %__MODULE__{code: -32_700, message: "Invalid JSON payload", data: data}
  end

  @doc "Builds an invalid request error (-32600)."
  @spec invalid_request(term()) :: t()
  def invalid_request(data \\ nil) do
    %__MODULE__{
      code: -32_600,
      message: "Request payload validation error",
      data: data
    }
  end

  @doc "Builds a method not found error (-32601)."
  @spec method_not_found(term()) :: t()
  def method_not_found(data \\ nil) do
    %__MODULE__{code: -32_601, message: "Method not found", data: data}
  end

  @doc "Builds an invalid params error (-32602)."
  @spec invalid_params(term()) :: t()
  def invalid_params(data \\ nil) do
    %__MODULE__{code: -32_602, message: "Invalid parameters", data: data}
  end

  @doc "Builds an internal error (-32603)."
  @spec internal_error(term()) :: t()
  def internal_error(data \\ nil) do
    %__MODULE__{code: -32_603, message: "Internal error", data: data}
  end

  @doc "Builds a task not found error (-32001)."
  @spec task_not_found(term()) :: t()
  def task_not_found(data \\ nil) do
    %__MODULE__{code: -32_001, message: "Task not found", data: data}
  end

  @doc "Builds a task not cancelable error (-32002)."
  @spec task_not_cancelable(term()) :: t()
  def task_not_cancelable(data \\ nil) do
    %__MODULE__{code: -32_002, message: "Task cannot be canceled", data: data}
  end

  @doc "Builds a push notification not supported error (-32003)."
  @spec push_notification_not_supported(term()) :: t()
  def push_notification_not_supported(data \\ nil) do
    %__MODULE__{
      code: -32_003,
      message: "Push Notification is not supported",
      data: data
    }
  end

  @doc "Builds an unsupported operation error (-32004)."
  @spec unsupported_operation(term()) :: t()
  def unsupported_operation(data \\ nil) do
    %__MODULE__{
      code: -32_004,
      message: "This operation is not supported",
      data: data
    }
  end

  @doc "Builds a content type not supported error (-32005)."
  @spec content_type_not_supported(term()) :: t()
  def content_type_not_supported(data \\ nil) do
    %__MODULE__{
      code: -32_005,
      message: "Incompatible content types",
      data: data
    }
  end

  @doc "Builds an invalid agent response error (-32006)."
  @spec invalid_agent_response(term()) :: t()
  def invalid_agent_response(data \\ nil) do
    %__MODULE__{
      code: -32_006,
      message: "Invalid agent response",
      data: data
    }
  end

  @doc "Builds an authenticated extended card not configured error (-32007)."
  @spec authenticated_extended_card_not_configured(term()) :: t()
  def authenticated_extended_card_not_configured(data \\ nil) do
    %__MODULE__{
      code: -32_007,
      message: "Authenticated Extended Card is not configured",
      data: data
    }
  end

  @doc "Builds an extension support required error (-32008)."
  @spec extension_support_required(term()) :: t()
  def extension_support_required(data \\ nil) do
    %__MODULE__{
      code: -32_008,
      message: "Extension support is required",
      data: data
    }
  end

  @doc "Builds a version not supported error (-32009)."
  @spec version_not_supported(term()) :: t()
  def version_not_supported(data \\ nil) do
    %__MODULE__{
      code: -32_009,
      message: "Version not supported",
      data: data
    }
  end

  @doc """
  Converts an error struct to a JSON-ready map.

  For A2A-specific codes (-32001..-32009) `"data"` is always an array carrying
  a `google.rpc.ErrorInfo` object; any free-form data is preserved under its
  `"metadata"`. For standard JSON-RPC codes `"data"` is passed through as-is
  and omitted when nil.

      iex> error = A2A.JSONRPC.Error.internal_error("boom")
      iex> A2A.JSONRPC.Error.to_map(error)
      %{"code" => -32603, "message" => "Internal error", "data" => "boom"}
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    base = %{"code" => error.code, "message" => error.message}

    case Map.fetch(@a2a_reasons, error.code) do
      {:ok, reason} -> Map.put(base, "data", error_details(error.data, reason))
      :error -> put_unless_nil(base, error.data)
    end
  end

  defp put_unless_nil(base, nil), do: base
  defp put_unless_nil(base, data), do: Map.put(base, "data", data)

  # Idempotent: an error decoded from the wire and re-serialized (a relay or
  # proxy path) already carries its ErrorInfo and must not be wrapped twice.
  defp error_details(data, reason) do
    if already_wrapped?(data), do: data, else: [error_info(reason, data)]
  end

  defp already_wrapped?(data) when is_list(data) do
    Enum.any?(data, &match?(%{"@type" => @error_info_type}, &1))
  end

  defp already_wrapped?(_), do: false

  defp error_info(reason, nil) do
    %{"@type" => @error_info_type, "domain" => @a2a_domain, "reason" => reason}
  end

  defp error_info(reason, detail) do
    Map.put(error_info(reason, nil), "metadata", %{"detail" => stringify(detail)})
  end

  defp stringify(detail) when is_binary(detail), do: detail
  defp stringify(detail), do: inspect(detail)
end
