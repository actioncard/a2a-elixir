defmodule A2A.PushNotificationSender do
  @moduledoc "Behaviour for sending push notifications."

  @type payload :: map()
  @callback send_notification(A2A.PushNotificationConfig.t(), payload()) :: :ok | {:error, term()}
end

defmodule A2A.PushNotificationSender.HTTP do
  @moduledoc "Default HTTP push notification sender."
  @behaviour A2A.PushNotificationSender

  @impl true
  def send_notification(config, payload) do
    headers = build_headers(config)
    body = Jason.encode!(payload)

    case Req.post(config.url, body: body, headers: headers) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_headers(%{authentication: %{scheme: scheme, credentials: creds}})
       when is_binary(scheme) do
    [{"content-type", "application/json"}, {"authorization", "#{scheme} #{creds || ""}"}]
  end

  defp build_headers(%{token: token}) when is_binary(token) do
    [{"content-type", "application/json"}, {"authorization", "Bearer #{token}"}]
  end

  defp build_headers(_), do: [{"content-type", "application/json"}]
end
