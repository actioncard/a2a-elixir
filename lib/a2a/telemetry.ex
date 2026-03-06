defmodule A2A.Telemetry do
  @moduledoc """
  Telemetry events emitted by the A2A library.

  A2A uses `:telemetry` to emit events at key lifecycle points. Library
  users attach handlers in their application to observe agent behaviour
  in production.

  ## Spans

  Spans are emitted via `:telemetry.span/3` and automatically produce
  `:start`, `:stop`, and `:exception` suffixed events.

  ### `[:a2a, :agent, :call]`

  Wraps the full `A2A.call/3` and `A2A.stream/3` lifecycle.

  **Start measurements:** `%{system_time: integer()}`

  **Start metadata:**

      %{agent: GenServer.server(), streaming: boolean()}

  **Stop measurements:** `%{duration: integer()}`

  **Stop metadata** (adds to start):

      %{task_id: String.t(), status: atom(), context_id: String.t() | nil}

  On error, stop metadata instead contains `%{error: term()}`.

  ### `[:a2a, :agent, :message]`

  Wraps the `handle_message/2` callback execution inside the agent
  GenServer.

  **Start measurements:** `%{system_time: integer()}`

  **Start metadata:**

      %{agent: module(), task_id: String.t(), context_id: String.t() | nil}

  **Stop measurements:** `%{duration: integer()}`

  **Stop metadata** (adds to start):

      %{reply_type: :reply | :stream | :input_required | :error}

  ### `[:a2a, :agent, :cancel]`

  Wraps the `handle_cancel/1` callback execution.

  **Start measurements:** `%{system_time: integer()}`

  **Start metadata:**

      %{agent: module(), task_id: String.t(), context_id: String.t() | nil}

  **Stop measurements:** `%{duration: integer()}`

  ## Discrete Events

  ### `[:a2a, :task, :transition]`

  Emitted on every task state change.

  **Measurements:**

      %{system_time: integer()}

  **Metadata:**

      %{
        task_id: String.t(),
        context_id: String.t() | nil,
        from: atom() | nil,
        to: atom()
      }
  """
end
