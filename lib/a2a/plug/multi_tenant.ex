if Code.ensure_loaded?(Plug) do
  defmodule A2A.Plug.MultiTenant do
    @moduledoc """
    Plug for multi-tenant A2A deployments with path-based routing.

    Routes requests matching `/:tenant/:agent/*path` to the correct agent
    process. This is an optional module — existing single-tenant usage
    via `A2A.Plug` is unaffected.

    ## Usage

        # In a Phoenix router:
        forward "/", A2A.Plug.MultiTenant,
          agents: %{
            "greeter" => GreeterAgent,
            "helper" => HelperAgent
          },
          base_url: "http://localhost:4000"

        # With a registry:
        forward "/", A2A.Plug.MultiTenant,
          registry: MyApp.AgentRegistry,
          base_url: "http://localhost:4000"

    This serves:
    - `GET /:tenant/:agent/.well-known/agent-card.json` — per-tenant agent card
    - `POST /:tenant/:agent/` — JSON-RPC dispatch with tenant context

    ## Options

    - `:agents` — static map of agent name to GenServer name/pid
    - `:registry` — `A2A.Registry` name for dynamic agent lookup
    - `:base_url` — public base URL (required)
    - `:plug_opts` — extra options forwarded to `A2A.Plug.init/1`

    ## Tenant Context

    Injects into `conn.assigns`:
    - `:a2a_tenant` — the tenant ID from the URL path
    - `:a2a_agent_name` — the agent name from the URL path

    Sets `"tenant_id"` in task metadata via `A2A.Plug.put_metadata/2`.
    """

    @behaviour Plug

    import Plug.Conn

    @impl Plug
    @spec init(keyword()) :: map()
    def init(opts) do
      agents = Keyword.get(opts, :agents)
      registry = Keyword.get(opts, :registry)

      unless agents || registry do
        raise ArgumentError,
              "A2A.Plug.MultiTenant requires either :agents map or :registry option"
      end

      %{
        agents: agents,
        registry: registry,
        base_url: Keyword.fetch!(opts, :base_url),
        plug_opts: Keyword.get(opts, :plug_opts, [])
      }
    end

    @impl Plug
    @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
    def call(%{path_info: [tenant, agent_name | rest]} = conn, opts) do
      case resolve_agent(agent_name, opts) do
        {:ok, agent_ref} ->
          conn =
            conn
            |> assign(:a2a_tenant, tenant)
            |> assign(:a2a_agent_name, agent_name)

          tenant_base_url = "#{opts.base_url}/#{tenant}/#{agent_name}"

          conn =
            conn
            |> A2A.Plug.put_base_url(tenant_base_url)
            |> A2A.Plug.put_metadata(%{"tenant_id" => tenant})

          plug_init_opts =
            [
              agent: agent_ref,
              base_url: opts.base_url
            ] ++ opts.plug_opts

          conn = %{conn | path_info: rest, script_name: conn.script_name ++ [tenant, agent_name]}

          a2a_opts = A2A.Plug.init(plug_init_opts)
          A2A.Plug.call(conn, a2a_opts)

        {:error, :not_found} ->
          conn
          |> send_resp(404, "Agent not found: #{agent_name}")
      end
    end

    def call(conn, _opts) do
      send_resp(conn, 404, "Not Found")
    end

    defp resolve_agent(name, %{agents: agents}) when is_map(agents) do
      case Map.fetch(agents, name) do
        {:ok, agent} -> {:ok, agent}
        :error -> {:error, :not_found}
      end
    end

    defp resolve_agent(name, %{registry: registry}) when not is_nil(registry) do
      entries = A2A.Registry.all(registry)

      case Enum.find(entries, fn {_mod, card} -> card.name == name end) do
        {mod, _card} -> {:ok, mod}
        nil -> {:error, :not_found}
      end
    end

    defp resolve_agent(_name, _opts), do: {:error, :not_found}
  end
end
