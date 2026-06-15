# JWT Authentication Example
#
# This example shows how to integrate A2A.Plug.JWTVerifier with
# A2A.Plug.Auth in a Phoenix application. Because a2a is a library,
# authentication wiring belongs in your application — not inside the
# library itself.
#
# Prerequisites:
#   {:a2a,    "~> 0.2"},
#   {:joken,  "~> 2.6"},
#   {:bandit, "~> 1.5"},
#   {:plug,   "~> 1.16"}

# ── 1. Define your agent ───────────────────────────────────────────

defmodule Example.SecureAgent do
  use A2A.Agent,
    name: "secure-agent",
    description: "An agent that requires JWT authentication",
    skills: [
      %{
        id: "echo",
        name: "Secure Echo",
        description: "Echoes messages with principal identity",
        tags: ["auth", "demo"]
      }
    ]

  @impl A2A.Agent
  def handle_message(message, context) do
    text = A2A.Message.text(message) || ""
    principal = get_in(context.metadata, ["a2a.auth", "identity", "sub"]) || "anonymous"

    {:reply, [A2A.Part.Text.new("Hello #{principal}, you said: #{text}")]}
  end
end

# ── 2. Build a JWT verify callback ─────────────────────────────────
#
# Create a verifier at runtime (not compile time!) and expose a
# callback matching the A2A.Plug.Auth :verify signature:
#
#   verify(scheme_name, credential, conn) :: {:ok, map()} | {:error, String.t()}

defmodule Example.Auth do
  @moduledoc false

  @doc """
  Returns a verify callback configured from runtime environment.

  ## Example

      verify_fn = Example.Auth.jwt_verify_callback(
        secret: System.get_env("JWT_SECRET", "dev-secret"),
        issuer: "https://auth.example.com",
        audience: "a2a-api"
      )

      plug A2A.Plug.Auth,
        schemes: %{"jwt" => %A2A.SecurityScheme.HTTPAuth{scheme: "bearer"}},
        verify: verify_fn
  """
  @spec jwt_verify_callback(keyword()) ::
          (String.t(), String.t(), Plug.Conn.t() ->
             {:ok, map()} | {:error, String.t()})
  def jwt_verify_callback(opts) do
    verifier = A2A.Plug.JWTVerifier.new(opts)

    fn _scheme_name, token, _conn ->
      case A2A.Plug.JWTVerifier.verify(verifier, token) do
        {:ok, claims} ->
          {:ok, build_identity(claims)}

        {:error, reason} ->
          {:error, "JWT verification failed: #{reason}"}
      end
    end
  end

  defp build_identity(claims) do
    principal_type = Map.get(claims, "principal_type", "user")
    sub = Map.get(claims, "sub", "unknown")

    %{
      "principal_id" => "#{principal_type}:#{sub}",
      "principal_type" => principal_type,
      "sub" => sub,
      "iss" => Map.get(claims, "iss"),
      "aud" => Map.get(claims, "aud"),
      "roles" => Map.get(claims, "roles", []),
      "permissions" => Map.get(claims, "permissions", [])
    }
  end
end

# ── 3. Wire up Plug pipeline ──────────────────────────────────────
#
# In a Phoenix router you'd use `pipeline` and `pipe_through`.
# This standalone example uses a Plug.Builder pipeline.

defmodule Example.AuthPipeline do
  use Plug.Builder

  plug A2A.Plug.Auth,
    schemes: %{
      "jwt" => %A2A.SecurityScheme.HTTPAuth{scheme: "bearer"}
    },
    verify:
      Example.Auth.jwt_verify_callback(
        secret: System.get_env("JWT_SECRET", "dev-secret-for-example"),
        algorithm: "HS256",
        required_claims: ["sub"]
      ),
    exempt_paths: [[".well-known", "agent-card.json"]]

  plug :forward_to_a2a

  defp forward_to_a2a(conn, _opts) do
    opts =
      A2A.Plug.init(
        agent: Example.SecureAgent,
        base_url: "http://localhost:4002"
      )

    A2A.Plug.call(conn, opts)
  end
end

# ── 4. Start and demo ─────────────────────────────────────────────

Example.SecureAgent.start_link()

{:ok, _} = Bandit.start_link(plug: Example.AuthPipeline, port: 4002)

IO.puts("""

JWT Auth Example running on http://localhost:4002

Endpoints:
  GET  /.well-known/agent-card.json  (no auth required)
  POST /                             (requires JWT bearer token)

To test with curl:

  # Agent card (no auth)
  curl http://localhost:4002/.well-known/agent-card.json

  # Generate a test JWT (use https://jwt.io or a script)
  # Then send an authenticated message:
  curl -X POST http://localhost:4002 \\
    -H "Content-Type: application/json" \\
    -H "Authorization: Bearer <your-jwt-token>" \\
    -d '{"jsonrpc":"2.0","id":1,"method":"message/send","params":{"message":{"messageId":"msg-1","role":"user","parts":[{"kind":"text","text":"Hello!"}]}}}'
""")

Process.sleep(:infinity)
