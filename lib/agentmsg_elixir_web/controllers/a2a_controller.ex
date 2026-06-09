if Code.ensure_loaded?(Plug) and Code.ensure_loaded?(Phoenix.Controller) do
  defmodule AgentmsgElixirWeb.A2AController do
    @moduledoc """
    Phoenix controller for A2A agent-to-agent communication with JWT authentication.

    This controller implements the A2A protocol endpoints with Principal authentication
    using JWT tokens validated against JWKS endpoints. It bridges the gap between
    simple test authentication and production-grade JWT validation.

    ## Principal Authentication

    Supports JWT bearer tokens with:
    - JWKS-based signature verification
    - Standard claims validation (exp, nbf, iat, sub)
    - Issuer and audience verification
    - Configurable claim requirements

    ## Endpoints

    - `POST /a2a/message` — Send message to agent
    - `GET /a2a/stream/:task_id` — Stream agent responses (SSE)
    - `GET /.well-known/agent-card.json` — Agent card (no auth required)

    ## Configuration

    Configure in your endpoint or router:

        pipeline :a2a_auth do
          plug A2A.Plug.Auth,
            schemes: %{
              "jwt_auth" => %A2A.SecurityScheme.HTTPAuth{scheme: "bearer"}
            },
            verify: &AgentmsgElixirWeb.A2AController.verify_jwt_token/3,
            exempt_paths: [
              [".well-known", "agent-card.json"]
            ]
        end

        scope "/", AgentmsgElixirWeb do
          pipe_through [:a2a_auth]
          
          post "/a2a/message", A2AController, :send_message
          get "/a2a/stream/:task_id", A2AController, :stream_response
          get "/.well-known/agent-card.json", A2AController, :agent_card
        end

    ## Environment Configuration

        config :agentmsg_elixir, AgentmsgElixirWeb.A2AController,
          jwt_verifier: %{
            jwks_url: "https://auth.example.com/.well-known/jwks.json",
            issuer: "https://auth.example.com",
            audience: "a2a-api",
            required_claims: ["sub", "principal_type"]
          },
          agent_module: MyApp.Agent,
          base_url: "https://myagent.example.com"
    """

    use Phoenix.Controller, formats: [:json]

    alias A2A.Plug.{Auth, JWTVerifier, SSE}
    alias A2A.{Agent, Task, Message}

    # Default configuration - override in your app config
    @default_config %{
      jwt_verifier: %{
        jwks_url:
          System.get_env("JWT_JWKS_URL", "https://auth.example.com/.well-known/jwks.json"),
        issuer: System.get_env("JWT_ISSUER", "https://auth.example.com"),
        audience: System.get_env("JWT_AUDIENCE", "a2a-api"),
        required_claims: ["sub", "principal_type"],
        clock_skew: 60,
        cache_ttl: 3600
      },
      # Must be configured
      agent_module: nil,
      base_url: System.get_env("A2A_BASE_URL", "http://localhost:4000")
    }

    # -- Public API --------------------------------------------------------------

    @doc """
    JWT verification callback for A2A.Plug.Auth.

    This function is called by the auth plug to verify JWT bearer tokens.
    It implements the Principal authentication flow with JWKS validation.

    ## Parameters

    - `scheme_name` — The authentication scheme name (typically "jwt_auth")
    - `token` — The JWT token extracted from the Authorization header
    - `conn` — The Plug connection

    ## Returns

    - `{:ok, identity}` — Authentication successful, contains principal claims
    - `{:error, reason}` — Authentication failed

    ## Principal Identity

    On successful authentication, the identity contains:

        %{
          "principal_id" => "user:alice@example.com",
          "principal_type" => "user",  # or "agent", "service"
          "sub" => "alice@example.com",
          "iss" => "https://auth.example.com",
          "aud" => "a2a-api",
          "exp" => 1234567890,
          # ... other JWT claims
        }

    ## Usage

        # In your router configuration:
        plug A2A.Plug.Auth,
          schemes: %{
            "jwt_auth" => %A2A.SecurityScheme.HTTPAuth{scheme: "bearer"}
          },
          verify: &AgentmsgElixirWeb.A2AController.verify_jwt_token/3
    """
    @spec verify_jwt_token(String.t(), String.t(), Plug.Conn.t()) ::
            {:ok, map()} | {:error, String.t()}
    def verify_jwt_token(_scheme_name, token, _conn) do
      config = get_config()
      verifier = JWTVerifier.new(config.jwt_verifier)

      case JWTVerifier.verify(verifier, token) do
        {:ok, claims} ->
          identity = build_principal_identity(claims)
          {:ok, identity}

        {:error, reason} ->
          {:error, "JWT verification failed: #{reason}"}
      end
    end

    @doc """
    Send a message to the agent.

    Requires JWT authentication. The principal identity from the JWT token
    is passed to the agent as context metadata.

    ## Request Body

        {
          "jsonrpc": "2.0",
          "id": 1,
          "method": "message/send",
          "params": {
            "message": {
              "messageId": "msg-123",
              "role": "user", 
              "parts": [
                {"kind": "text", "text": "Hello, agent!"}
              ]
            }
          }
        }

    ## Response

        {
          "jsonrpc": "2.0",
          "id": 1,
          "result": {
            "task": {
              "taskId": "task-456",
              "status": "running",
              "metadata": {
                "a2a.auth": {
                  "scheme": "jwt_auth",
                  "identity": {
                    "principal_id": "user:alice@example.com",
                    "principal_type": "user",
                    "sub": "alice@example.com"
                  }
                }
              }
            }
          }
        }
    """
    def send_message(conn, _params) do
      config = get_config()

      unless config.agent_module do
        send_error(conn, 500, "Agent module not configured")
      else
        # Use A2A.Plug for standard JSON-RPC handling with auth
        plug_opts =
          A2A.Plug.init(
            agent: config.agent_module,
            base_url: config.base_url
          )

        A2A.Plug.call(conn, plug_opts)
      end
    end

    @doc """
    Stream agent responses via Server-Sent Events.

    Requires JWT authentication. Streams real-time updates for the specified task.

    ## Parameters

    - `task_id` — The task ID to stream updates for

    ## Response

    Server-Sent Events stream with task status updates:

        event: task_update
        data: {"taskId": "task-456", "status": "running"}

        event: task_update  
        data: {"taskId": "task-456", "status": "completed", "result": {...}}
    """
    def stream_response(conn, %{"task_id" => task_id}) do
      config = get_config()

      unless config.agent_module do
        send_error(conn, 500, "Agent module not configured")
      else
        # Verify the task exists and user has access
        case verify_task_access(task_id, conn) do
          :ok ->
            # Use A2A.Plug.SSE for streaming
            sse_opts =
              SSE.init(
                task_id: task_id,
                base_url: config.base_url
              )

            SSE.call(conn, sse_opts)

          {:error, reason} ->
            send_error(conn, 403, "Access denied: #{reason}")
        end
      end
    end

    @doc """
    Return the agent card.

    This endpoint is exempt from authentication and returns the agent's
    capabilities and metadata.

    ## Response

        {
          "name": "Example Agent",
          "version": "1.0.0",
          "description": "An example A2A agent",
          "author": "Example Corp",
          "security": [
            {
              "jwt_auth": []
            }
          ],
          "extensions": [...],
          "metadata": {...}
        }
    """
    def agent_card(conn, _params) do
      config = get_config()

      unless config.agent_module do
        send_error(conn, 500, "Agent module not configured")
      else
        case Agent.card(config.agent_module) do
          {:ok, card} ->
            # Add security schemes to advertise JWT auth
            card_with_security = add_security_schemes(card)

            conn
            |> put_resp_content_type("application/json")
            |> json(card_with_security)

          {:error, reason} ->
            send_error(conn, 500, "Failed to get agent card: #{inspect(reason)}")
        end
      end
    end

    # -- Private helpers ---------------------------------------------------------

    defp get_config do
      app_config = Application.get_env(:agentmsg_elixir, __MODULE__, %{})
      Map.merge(@default_config, app_config)
    end

    defp build_principal_identity(claims) do
      principal_type = Map.get(claims, "principal_type", "user")
      sub = Map.get(claims, "sub")

      principal_id =
        case {principal_type, sub} do
          {type, sub} when is_binary(sub) -> "#{type}:#{sub}"
          {_, _} -> "unknown:#{System.unique_integer([:positive])}"
        end

      %{
        "principal_id" => principal_id,
        "principal_type" => principal_type,
        "sub" => sub,
        "iss" => Map.get(claims, "iss"),
        "aud" => Map.get(claims, "aud"),
        "exp" => Map.get(claims, "exp"),
        "iat" => Map.get(claims, "iat"),
        "roles" => Map.get(claims, "roles", []),
        "permissions" => Map.get(claims, "permissions", [])
      }
    end

    defp verify_task_access(task_id, conn) do
      # Get the authenticated identity
      case Auth.get_identity(conn) do
        nil ->
          {:error, "not authenticated"}

        _identity ->
          # In a real implementation, you would check if the principal
          # has access to the specific task. For now, just verify the task exists.
          case Task.get(task_id) do
            {:ok, _task} -> :ok
            {:error, :not_found} -> {:error, "task not found"}
            {:error, reason} -> {:error, reason}
          end
      end
    end

    defp add_security_schemes(card) do
      jwt_security = %{
        "jwt_auth" => []
      }

      existing_security = Map.get(card, "security", [])
      new_security = [jwt_security | existing_security]

      Map.put(card, "security", new_security)
    end

    defp send_error(conn, status, message) do
      conn
      |> put_status(status)
      |> put_resp_content_type("application/json")
      |> json(%{"error" => message})
      |> halt()
    end
  end
else
  defmodule AgentmsgElixirWeb.A2AController do
    @moduledoc """
    A2A Controller - requires Phoenix and Plug to be loaded.

    Add `{:phoenix, "~> 1.7"}` to your dependencies to use this module.
    """

    def __using__(_opts) do
      raise """
      AgentmsgElixirWeb.A2AController requires Phoenix and Plug.

      Add to your mix.exs dependencies:

        {:phoenix, "~> 1.7"},
        {:plug, "~> 1.16"}
      """
    end
  end
end
