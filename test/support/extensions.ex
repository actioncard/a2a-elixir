defmodule A2A.Test.Extensions.Timestamp do
  @moduledoc false
  @behaviour A2A.Extension

  @uri "https://example.test/ext/timestamp"

  @impl true
  def declaration(_state) do
    %A2A.AgentExtension{uri: @uri, description: "Adds timestamps"}
  end

  @impl true
  def activate(_requested, _ctx, _state) do
    {:ok, %{started_at: 1_700_000_000_000}}
  end

  @impl true
  def handle_request(message, params, state) do
    message = A2A.Extension.put_metadata(message, __MODULE__, %{seen_at: state.started_at})
    {:ok, message, params, state}
  end

  @impl true
  def handle_response(task, _params, state) do
    task = A2A.Extension.put_metadata(task, __MODULE__, %{finished_at: state.started_at})
    {:ok, task, state}
  end
end

defmodule A2A.Test.Extensions.Passport do
  @moduledoc false
  @behaviour A2A.Extension

  @uri "https://example.test/ext/passport"

  @impl true
  def init(opts), do: Keyword.get(opts, :issuer, "default")

  @impl true
  def declaration(_state) do
    %A2A.AgentExtension{uri: @uri, required: true, description: "Passport"}
  end

  @impl true
  def activate(_requested, _ctx, issuer), do: {:ok, %{issuer: issuer}}
end

defmodule A2A.Test.Extensions.SkipMe do
  @moduledoc false
  @behaviour A2A.Extension

  @uri "https://example.test/ext/skip"

  @impl true
  def declaration(_state) do
    %A2A.AgentExtension{uri: @uri, description: "Always skips"}
  end

  @impl true
  def activate(_requested, _ctx, _state), do: :skip
end

defmodule A2A.Test.Extensions.DataOnly do
  @moduledoc false
  @behaviour A2A.Extension

  @uri "https://example.test/ext/data-only"

  @impl true
  def declaration(_state) do
    %A2A.AgentExtension{
      uri: @uri,
      description: "Pure declaration, no hooks",
      params: %{"category" => "data-only"}
    }
  end
end
