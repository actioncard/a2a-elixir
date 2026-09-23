defmodule A2A.PushNotificationSender do
  @moduledoc """
  Behaviour for delivering push notification payloads to a client's webhook.

  An agent that stores push notification configs (see
  `A2A.PushNotificationConfig`) POSTs a payload to each registered URL every
  time one of its tasks changes state. This behaviour is the seam where that
  POST happens, so a host can route deliveries through its own queue, retry
  policy or egress proxy instead of the bundled HTTP sender.

  `A2A.PushNotificationSender.HTTP` is the default and is used automatically
  when `:req` is available. Pass your own with `:push_sender`:

      MyAgent.start_link(push_sender: {MyApp.Webhooks, queue: :webhooks})

  ## Payload

  `payload` is a decoded `StreamResponse` map carrying exactly one of `task`,
  `message`, `statusUpdate` or `artifactUpdate` — the same shape the streaming
  transport emits, per the spec's Push Notification Payload section. Encode it
  with `Jason.encode/1`; do not wrap it in a JSON-RPC envelope.

  ## Contract

  Implementations MUST NOT block: the callback is invoked from a short-lived
  process spawned by the agent, and a slow webhook must not stall task
  processing for other callers. Returning `{:error, reason}` is reported
  through telemetry and otherwise ignored — delivery is best-effort, which is
  what the spec requires (at least one attempt, retries optional).

  Implementations MUST send the credentials from `config.authentication` as an
  HTTP `Authorization` header. That is the one hard requirement the spec places
  on the caller.
  """

  @doc """
  Delivers one payload to the webhook described by `config`.

  Called once per registered config per task state change.
  """
  @callback deliver(
              config :: A2A.PushNotificationConfig.t(),
              payload :: map(),
              opts :: keyword()
            ) :: :ok | {:error, term()}
end
