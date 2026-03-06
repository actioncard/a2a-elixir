if Code.ensure_loaded?(Plug) do
  defmodule A2A.Plug.Auth do
    @moduledoc """
    Plug middleware for A2A agent authentication.

    Extracts credentials from incoming requests based on configured security
    schemes and delegates validation to a user-supplied `verify` callback.
    On success, the verified identity is stored in `conn.private[:a2a][:auth]`
    where `A2A.Plug` can forward it to the agent as `context.metadata["a2a.auth"]`.

    ## Usage

        # In a Phoenix pipeline or plug pipeline, before A2A.Plug:
        plug A2A.Plug.Auth,
          schemes: %{
            "bearer_auth" => %A2A.SecurityScheme.HTTPAuth{scheme: "bearer"}
          },
          verify: &MyApp.Auth.verify_a2a/3

        forward "/a2a", A2A.Plug, agent: MyAgent, base_url: "..."

    ## Options

    - `:schemes` — `%{String.t() => SecurityScheme.t()}` mapping scheme names
      to their definitions (required)
    - `:verify` — `(scheme_name, credential, conn) -> {:ok, identity} | {:error, reason}`
      callback for credential validation (required)
    - `:security` — `[%{String.t() => [String.t()]}]` list of security
      requirement alternatives. Each map requires all its schemes (AND); the
      first fully-satisfied alternative wins (OR). Defaults to each scheme as
      an independent alternative.
    - `:exempt_paths` — list of path_info lists that bypass authentication
      (default: `[[".well-known", "agent-card.json"]]`)
    - `:realm` — realm string for WWW-Authenticate headers (default: `"a2a"`)

    ## Verify Callback

    The callback receives the scheme name, extracted credential, and conn:

        def verify(scheme_name, credential, conn)

    Where `credential` is:
    - `String.t()` for Bearer tokens, API keys, OAuth2, OpenID Connect
    - `{username, password}` for HTTP Basic auth

    Must return `{:ok, identity_map}` or `{:error, reason_string}`.
    """

    @behaviour Plug

    import Plug.Conn

    alias A2A.SecurityScheme.{APIKey, HTTPAuth, MutualTLS, OAuth2, OpenIDConnect}

    @default_exempt_paths [[".well-known", "agent-card.json"]]
    @default_realm "a2a"

    # -- Public helpers --------------------------------------------------------

    @doc """
    Returns the authenticated identity from `conn.private[:a2a][:auth]`, or
    `nil` if no identity is stored.
    """
    @spec get_identity(Plug.Conn.t()) :: map() | nil
    def get_identity(conn) do
      conn.private |> Map.get(:a2a, %{}) |> Map.get(:auth)
    end

    @doc """
    Stores an authenticated identity in `conn.private[:a2a][:auth]`.

    Called automatically on successful authentication, but also available
    for use in custom auth plugs that want to integrate with `A2A.Plug`.
    """
    @spec put_identity(Plug.Conn.t(), map()) :: Plug.Conn.t()
    def put_identity(conn, identity) when is_map(identity) do
      a2a = Map.get(conn.private, :a2a, %{})
      put_private(conn, :a2a, Map.put(a2a, :auth, identity))
    end

    # -- Plug callbacks --------------------------------------------------------

    @impl Plug
    @spec init(keyword()) :: map()
    def init(opts) do
      schemes = validate_schemes!(opts)
      verify = validate_verify!(opts)
      security = validate_security!(opts, schemes)
      exempt_paths = Keyword.get(opts, :exempt_paths, @default_exempt_paths)
      realm = Keyword.get(opts, :realm, @default_realm)

      %{
        schemes: schemes,
        verify: verify,
        security: security,
        exempt_paths: exempt_paths,
        realm: realm
      }
    end

    @impl Plug
    @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
    def call(conn, opts) do
      if exempt?(conn, opts.exempt_paths) do
        conn
      else
        authenticate(conn, opts)
      end
    end

    # -- Init-time validation --------------------------------------------------

    defp validate_schemes!(opts) do
      case Keyword.get(opts, :schemes) do
        nil ->
          raise ArgumentError, "A2A.Plug.Auth requires :schemes option"

        schemes when is_map(schemes) and map_size(schemes) > 0 ->
          schemes

        _ ->
          raise ArgumentError,
                "A2A.Plug.Auth :schemes must be a non-empty map"
      end
    end

    defp validate_verify!(opts) do
      case Keyword.get(opts, :verify) do
        fun when is_function(fun, 3) ->
          fun

        nil ->
          raise ArgumentError, "A2A.Plug.Auth requires :verify option"

        _ ->
          raise ArgumentError,
                "A2A.Plug.Auth :verify must be a function with arity 3"
      end
    end

    defp validate_security!(opts, schemes) do
      case Keyword.get(opts, :security) do
        nil ->
          # Default: each scheme as an independent alternative (OR)
          Enum.map(schemes, fn {name, _} -> %{name => []} end)

        alternatives when is_list(alternatives) ->
          validate_security_refs!(alternatives, schemes)
          alternatives
      end
    end

    defp validate_security_refs!(alternatives, schemes) do
      scheme_names = Map.keys(schemes) |> MapSet.new()

      Enum.each(alternatives, fn alt ->
        Enum.each(alt, fn {name, _scopes} ->
          unless MapSet.member?(scheme_names, name) do
            raise ArgumentError,
                  "A2A.Plug.Auth :security references unknown scheme #{inspect(name)}"
          end
        end)
      end)
    end

    # -- Path exemption --------------------------------------------------------

    defp exempt?(conn, exempt_paths) do
      Enum.any?(exempt_paths, &(&1 == conn.path_info))
    end

    # -- Authentication flow ---------------------------------------------------

    defp authenticate(conn, opts) do
      case evaluate_alternatives(conn, opts) do
        {:ok, identity} ->
          put_identity(conn, identity)

        :unauthorized ->
          send_unauthorized(conn, opts)
      end
    end

    defp evaluate_alternatives(conn, opts) do
      Enum.reduce_while(opts.security, :unauthorized, fn alt, _acc ->
        case evaluate_requirements(conn, alt, opts) do
          {:ok, identities} ->
            identity = build_identity(alt, identities)
            {:halt, {:ok, identity}}

          :unauthorized ->
            {:cont, :unauthorized}
        end
      end)
    end

    defp evaluate_requirements(conn, requirements, opts) do
      results =
        Enum.reduce_while(requirements, %{}, fn {name, _scopes}, acc ->
          scheme = Map.fetch!(opts.schemes, name)

          case extract_credential(conn, scheme) do
            {:ok, credential} ->
              case opts.verify.(name, credential, conn) do
                {:ok, identity} ->
                  {:cont, Map.put(acc, name, identity)}

                {:error, _reason} ->
                  {:halt, :unauthorized}
              end

            :missing ->
              {:halt, :unauthorized}

            :unsupported ->
              {:halt, :unauthorized}
          end
        end)

      case results do
        :unauthorized -> :unauthorized
        identities when is_map(identities) -> {:ok, identities}
      end
    end

    defp build_identity(requirements, identities) do
      names = Map.keys(requirements)

      case names do
        [single] ->
          %{scheme: single, identity: Map.fetch!(identities, single)}

        _multiple ->
          first = hd(names)

          %{
            scheme: first,
            identity: Map.fetch!(identities, first),
            identities: identities
          }
      end
    end

    # -- Credential extraction -------------------------------------------------

    defp extract_credential(conn, %HTTPAuth{scheme: "bearer"}) do
      extract_bearer(conn)
    end

    defp extract_credential(conn, %HTTPAuth{scheme: "basic"}) do
      extract_basic(conn)
    end

    defp extract_credential(conn, %HTTPAuth{}) do
      # Other HTTP auth schemes — try bearer-style extraction
      extract_bearer(conn)
    end

    defp extract_credential(conn, %APIKey{in: "header", name: name}) do
      case get_req_header(conn, String.downcase(name)) do
        [value | _] -> {:ok, value}
        [] -> :missing
      end
    end

    defp extract_credential(conn, %APIKey{in: "query", name: name}) do
      conn = fetch_query_params(conn)

      case conn.query_params[name] do
        nil -> :missing
        value -> {:ok, value}
      end
    end

    defp extract_credential(conn, %APIKey{in: "cookie", name: name}) do
      conn = fetch_cookies(conn)

      case conn.req_cookies[name] do
        nil -> :missing
        value -> {:ok, value}
      end
    end

    defp extract_credential(conn, %OAuth2{}) do
      extract_bearer(conn)
    end

    defp extract_credential(conn, %OpenIDConnect{}) do
      extract_bearer(conn)
    end

    defp extract_credential(_conn, %MutualTLS{}) do
      :unsupported
    end

    defp extract_bearer(conn) do
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token | _] -> {:ok, token}
        _ -> :missing
      end
    end

    defp extract_basic(conn) do
      case get_req_header(conn, "authorization") do
        ["Basic " <> encoded | _] ->
          case Base.decode64(encoded) do
            {:ok, decoded} ->
              case String.split(decoded, ":", parts: 2) do
                [user, pass] -> {:ok, {user, pass}}
                _ -> :missing
              end

            :error ->
              :missing
          end

        _ ->
          :missing
      end
    end

    # -- Error response --------------------------------------------------------

    defp send_unauthorized(conn, opts) do
      conn =
        opts.schemes
        |> Enum.reduce(conn, fn {_name, scheme}, conn ->
          add_www_authenticate(conn, scheme, opts.realm)
        end)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode!(%{"error" => "Unauthorized"}))
      |> halt()
    end

    defp add_www_authenticate(conn, %HTTPAuth{scheme: scheme}, realm) do
      challenge =
        "#{String.capitalize(scheme)} realm=#{inspect(realm)}"

      put_resp_header(conn, "www-authenticate", challenge)
    end

    defp add_www_authenticate(conn, %OAuth2{}, realm) do
      put_resp_header(conn, "www-authenticate", "Bearer realm=#{inspect(realm)}")
    end

    defp add_www_authenticate(conn, %OpenIDConnect{}, realm) do
      put_resp_header(conn, "www-authenticate", "Bearer realm=#{inspect(realm)}")
    end

    # API key and mTLS have no standard WWW-Authenticate header
    defp add_www_authenticate(conn, _scheme, _realm), do: conn
  end
end
