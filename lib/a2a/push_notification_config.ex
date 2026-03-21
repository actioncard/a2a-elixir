defmodule A2A.PushNotificationConfig do
  @moduledoc "A push notification configuration associated with a task."

  @type t :: %__MODULE__{
          id: String.t() | nil,
          task_id: String.t() | nil,
          url: String.t(),
          token: String.t() | nil,
          authentication: A2A.AuthenticationInfo.t() | nil
        }

  defstruct [:id, :task_id, :url, :token, :authentication]
end
