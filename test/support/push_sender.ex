defmodule A2A.Test.PushSender do
  @moduledoc false

  @behaviour A2A.PushNotificationSender

  # Reports each delivery back to the test process instead of making an HTTP
  # request, so dispatch can be asserted without a webhook receiver.
  @impl A2A.PushNotificationSender
  def deliver(config, payload, opts) do
    pid = Keyword.fetch!(opts, :pid)
    send(pid, {:push_delivered, config, payload})
    Keyword.get(opts, :result, :ok)
  end
end
