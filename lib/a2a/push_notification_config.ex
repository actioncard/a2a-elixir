defmodule A2A.PushNotificationConfig do
  @moduledoc """
  Webhook configuration for push notifications on a task.

  Mirrors the `TaskPushNotificationConfig` object from the A2A v1.0 spec. A
  task may carry several configs, each identified by `:id` within the scope of
  its `:task_id`.

  Registering a config is a declaration of intent only — this library stores
  and serves configs but does not yet deliver webhooks. See the "Push
  Notifications" section of `SPEC.md`.

  ## Fields

    * `:id` — identifier, unique per task. Generated when the client omits it.
    * `:task_id` — the task this config belongs to (required)
    * `:url` — webhook endpoint that receives task updates (required)
    * `:token` — opaque token echoed back to the webhook for validation
    * `:authentication` — credentials the server presents when calling the
      webhook: `%{scheme: "Bearer", credentials: "..."}`

  ## Examples

      %A2A.PushNotificationConfig{
        id: "pcfg-a1B2c3D4e5F6",
        task_id: "tsk-a1B2c3D4e5F6",
        url: "https://example.com/webhook",
        authentication: %{scheme: "Bearer", credentials: "s3cret"}
      }
  """

  @type authentication :: %{
          optional(:scheme) => String.t(),
          optional(:credentials) => String.t() | nil
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          task_id: String.t() | nil,
          url: String.t(),
          token: String.t() | nil,
          authentication: authentication() | nil
        }

  @enforce_keys [:url]
  defstruct [:id, :task_id, :url, :token, :authentication]
end
