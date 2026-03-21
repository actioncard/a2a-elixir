defmodule A2A.TaskPushNotificationConfig do
  @moduledoc """
  A push notification configuration associated with a specific task.

  ## Proto Reference

      message TaskPushNotificationConfig {
        string tenant = 1;
        string id = 2;
        string task_id = 3;
        string url = 4;      // REQUIRED
        string token = 5;
        AuthenticationInfo authentication = 6;
      }
  """

  @type t :: %__MODULE__{
          tenant: String.t() | nil,
          id: String.t() | nil,
          task_id: String.t() | nil,
          url: String.t(),
          token: String.t() | nil,
          authentication: A2A.AuthenticationInfo.t() | nil
        }

  @enforce_keys [:url]
  defstruct [:tenant, :id, :task_id, :url, :token, :authentication]
end
