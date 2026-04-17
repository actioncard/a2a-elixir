defmodule A2A.SendMessageConfiguration do
  @moduledoc """
  Configuration for a send message request.

  ## Proto Reference

      message SendMessageConfiguration {
        repeated string accepted_output_modes = 1;
        TaskPushNotificationConfig task_push_notification_config = 2;
        optional int32 history_length = 3;
        bool return_immediately = 4;
      }
  """

  @type t :: %__MODULE__{
          accepted_output_modes: [String.t()],
          task_push_notification_config: A2A.TaskPushNotificationConfig.t() | nil,
          history_length: integer() | nil,
          return_immediately: boolean()
        }

  defstruct accepted_output_modes: [],
            task_push_notification_config: nil,
            history_length: nil,
            return_immediately: false
end
