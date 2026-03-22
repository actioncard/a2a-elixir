defmodule A2A.Plug.AuthTest do
  use ExUnit.Case, async: true

  @moduletag :plug

  alias A2A.Plug.Auth
  alias A2A.SecurityScheme.{APIKey, HTTPAuth, OAuth2, OpenIDConnect}

  # -- Helpers -----------------------------------------------------------------

  defp auth_opts(overrides \\ []) do
    defaults = [
      schemes: %{
        "bearer_auth" => %HTTPAuth{scheme: "bearer"}
      },
      verify: fn _name, _cred, _conn -> {:ok, %{"user_id" => "u-1"}} end
    ]

    Auth.init(Keyword.merge(defaults, overrides))
  end

  defp conn_with_bearer(token) do
    Plug.Test.conn(:post, "/")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
  end

  defp conn_with_basic(user, pass) do
    encoded = Base.encode64("#{user}:#{pass}")

    Plug.Test.conn(:post, "/")
    |> Plug.Conn.put_req_header("authorization", "Basic #{encoded}")
  end

  defp get_resp_header(conn, key) do
    for {k, v} <- conn.resp_headers, k == key, do: v
  end

  # -- Bearer token ------------------------------------------------------------

  describe "bearer token" do
    test "happy path — valid bearer token" do
      opts = auth_opts()
      conn = conn_with_bearer("valid-token") |> Auth.call(opts)

      refute conn.halted
      assert Auth.get_identity(conn) == %{scheme: "bearer_auth", identity: %{"user_id" => "u-1"}}
    end

    test "missing authorization header returns 401" do
      opts = auth_opts()
      conn = Plug.Test.conn(:post, "/") |> Auth.call(opts)

      assert conn.status == 401
      assert conn.halted
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Unauthorized"
    end

    test "invalid token returns 401" do
      opts =
        auth_opts(verify: fn _name, _cred, _conn -> {:error, "invalid token"} end)

      conn = conn_with_bearer("bad-token") |> Auth.call(opts)

      assert conn.status == 401
      assert conn.halted
    end

    test "malformed authorization header (no Bearer prefix) returns 401" do
      opts = auth_opts()

      conn =
        Plug.Test.conn(:post, "/")
        |> Plug.Conn.put_req_header("authorization", "Token abc123")
        |> Auth.call(opts)

      assert conn.status == 401
      assert conn.halted
    end
  end

  # -- Basic auth --------------------------------------------------------------

  describe "basic auth" do
    setup do
      opts =
        auth_opts(
          schemes: %{
            "basic_auth" => %HTTPAuth{scheme: "basic"}
          },
          verify: fn _name, {user, pass}, _conn ->
            if user == "admin" and pass == "secret",
              do: {:ok, %{"user" => user}},
              else: {:error, "bad credentials"}
          end
        )

      {:ok, opts: opts}
    end

    test "happy path — valid credentials", %{opts: opts} do
      conn = conn_with_basic("admin", "secret") |> Auth.call(opts)

      refute conn.halted

      assert Auth.get_identity(conn) ==
               %{scheme: "basic_auth", identity: %{"user" => "admin"}}
    end

    test "malformed base64 returns 401", %{opts: opts} do
      conn =
        Plug.Test.conn(:post, "/")
        |> Plug.Conn.put_req_header("authorization", "Basic !!!notbase64!!!")
        |> Auth.call(opts)

      assert conn.status == 401
      assert conn.halted
    end

    test "wrong credentials return 401", %{opts: opts} do
      conn = conn_with_basic("admin", "wrong") |> Auth.call(opts)

      assert conn.status == 401
      assert conn.halted
    end
  end

  # -- API key in header -------------------------------------------------------

  describe "API key in header" do
    setup do
      opts =
        auth_opts(
          schemes: %{
            "api_key" => %APIKey{in: "header", name: "X-Api-Key"}
          },
          verify: fn _name, key, _conn ->
            if key == "valid-key",
              do: {:ok, %{"key_id" => "k-1"}},
              else: {:error, "invalid key"}
          end
        )

      {:ok, opts: opts}
    end

    test "happy path — valid API key", %{opts: opts} do
      conn =
        Plug.Test.conn(:post, "/")
        |> Plug.Conn.put_req_header("x-api-key", "valid-key")
        |> Auth.call(opts)

      refute conn.halted

      assert Auth.get_identity(conn) ==
               %{scheme: "api_key", identity: %{"key_id" => "k-1"}}
    end

    test "missing header returns 401", %{opts: opts} do
      conn = Plug.Test.conn(:post, "/") |> Auth.call(opts)

      assert conn.status == 401
      assert conn.halted
    end
  end

  # -- API key in query --------------------------------------------------------

  describe "API key in query" do
    setup do
      opts =
        auth_opts(
          schemes: %{
            "api_key" => %APIKey{in: "query", name: "api_key"}
          },
          verify: fn _name, key, _conn ->
            if key == "qk-1",
              do: {:ok, %{"key_id" => "k-1"}},
              else: {:error, "invalid key"}
          end
        )

      {:ok, opts: opts}
    end

    test "happy path — valid query param", %{opts: opts} do
      conn =
        Plug.Test.conn(:post, "/?api_key=qk-1")
        |> Auth.call(opts)

      refute conn.halted

      assert Auth.get_identity(conn) ==
               %{scheme: "api_key", identity: %{"key_id" => "k-1"}}
    end

    test "missing query param returns 401", %{opts: opts} do
      conn = Plug.Test.conn(:post, "/") |> Auth.call(opts)

      assert conn.status == 401
      assert conn.halted
    end
  end

  # -- API key in cookie -------------------------------------------------------

  describe "API key in cookie" do
    setup do
      opts =
        auth_opts(
          schemes: %{
            "api_key" => %APIKey{in: "cookie", name: "session"}
          },
          verify: fn _name, val, _conn ->
            if val == "sess-1",
              do: {:ok, %{"session" => val}},
              else: {:error, "invalid session"}
          end
        )

      {:ok, opts: opts}
    end

    test "happy path — valid cookie", %{opts: opts} do
      conn =
        Plug.Test.conn(:post, "/")
        |> Plug.Conn.put_req_header("cookie", "session=sess-1")
        |> Auth.call(opts)

      refute conn.halted

      assert Auth.get_identity(conn) ==
               %{scheme: "api_key", identity: %{"session" => "sess-1"}}
    end

    test "missing cookie returns 401", %{opts: opts} do
      conn = Plug.Test.conn(:post, "/") |> Auth.call(opts)

      assert conn.status == 401
      assert conn.halted
    end
  end

  # -- Path exemption ----------------------------------------------------------

  describe "path exemption" do
    test "agent card path bypasses auth" do
      opts = auth_opts()

      conn =
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> Auth.call(opts)

      refute conn.halted
      assert Auth.get_identity(conn) == nil
    end

    test "custom exempt paths bypass auth" do
      opts = auth_opts(exempt_paths: [["health"], ["ready"]])

      conn = Plug.Test.conn(:get, "/health") |> Auth.call(opts)
      refute conn.halted

      conn = Plug.Test.conn(:get, "/ready") |> Auth.call(opts)
      refute conn.halted

      # Non-exempt path without credentials returns 401
      conn = Plug.Test.conn(:post, "/api") |> Auth.call(opts)
      assert conn.status == 401
    end
  end

  # -- Security alternatives (OR) ----------------------------------------------

  describe "security alternatives (OR)" do
    test "first scheme fails, second succeeds" do
      opts =
        auth_opts(
          schemes: %{
            "bearer_auth" => %HTTPAuth{scheme: "bearer"},
            "api_key" => %APIKey{in: "header", name: "X-Api-Key"}
          },
          security: [
            %{"bearer_auth" => []},
            %{"api_key" => []}
          ],
          verify: fn
            "bearer_auth", _cred, _conn -> {:error, "no bearer"}
            "api_key", _cred, _conn -> {:ok, %{"key" => "k-1"}}
          end
        )

      conn =
        Plug.Test.conn(:post, "/")
        |> Plug.Conn.put_req_header("x-api-key", "some-key")
        |> Auth.call(opts)

      refute conn.halted
      assert Auth.get_identity(conn) == %{scheme: "api_key", identity: %{"key" => "k-1"}}
    end
  end

  # -- Security requirements (AND) ---------------------------------------------

  describe "security requirements (AND)" do
    setup do
      opts =
        auth_opts(
          schemes: %{
            "bearer_auth" => %HTTPAuth{scheme: "bearer"},
            "api_key" => %APIKey{in: "header", name: "X-Api-Key"}
          },
          security: [
            %{"bearer_auth" => [], "api_key" => []}
          ],
          verify: fn
            "bearer_auth", token, _conn ->
              if token == "valid",
                do: {:ok, %{"user" => "u-1"}},
                else: {:error, "bad token"}

            "api_key", key, _conn ->
              if key == "valid-key",
                do: {:ok, %{"key" => "k-1"}},
                else: {:error, "bad key"}
          end
        )

      {:ok, opts: opts}
    end

    test "both required — both present and valid", %{opts: opts} do
      conn =
        Plug.Test.conn(:post, "/")
        |> Plug.Conn.put_req_header("authorization", "Bearer valid")
        |> Plug.Conn.put_req_header("x-api-key", "valid-key")
        |> Auth.call(opts)

      refute conn.halted
      identity = Auth.get_identity(conn)
      assert identity.identities["bearer_auth"] == %{"user" => "u-1"}
      assert identity.identities["api_key"] == %{"key" => "k-1"}
    end

    test "both required — one fails", %{opts: opts} do
      conn =
        Plug.Test.conn(:post, "/")
        |> Plug.Conn.put_req_header("authorization", "Bearer valid")
        |> Auth.call(opts)

      assert conn.status == 401
      assert conn.halted
    end
  end

  # -- Identity storage --------------------------------------------------------

  describe "identity storage" do
    test "get_identity/1 returns nil when not set" do
      conn = Plug.Test.conn(:get, "/")
      assert Auth.get_identity(conn) == nil
    end

    test "put_identity/2 and get_identity/1 round-trip" do
      identity = %{scheme: "test", identity: %{"id" => "1"}}

      conn =
        Plug.Test.conn(:get, "/")
        |> Auth.put_identity(identity)

      assert Auth.get_identity(conn) == identity
    end

    test "put_identity/2 preserves existing :a2a private data" do
      conn =
        Plug.Test.conn(:get, "/")
        |> A2A.Plug.put_metadata(%{"env" => "test"})
        |> Auth.put_identity(%{scheme: "test", identity: %{}})

      assert A2A.Plug.get_metadata(conn) == %{"env" => "test"}
      assert Auth.get_identity(conn) == %{scheme: "test", identity: %{}}
    end
  end

  # -- Integration: auth identity flows through A2A.Plug -----------------------

  describe "integration with A2A.Plug" do
    test "auth identity flows to task metadata" do
      agent = start_supervised!({A2A.Test.EchoAgent, [name: nil]})

      auth_opts =
        Auth.init(
          schemes: %{
            "bearer_auth" => %HTTPAuth{scheme: "bearer"}
          },
          verify: fn _name, _cred, _conn ->
            {:ok, %{"user_id" => "u-1"}}
          end
        )

      plug_opts =
        A2A.Plug.init(agent: agent, base_url: "http://localhost:4000")

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "message/send",
          "params" => %{
            "message" => %{
              "messageId" => "msg-test",
              "role" => "user",
              "parts" => [%{"kind" => "text", "text" => "hello"}]
            }
          }
        })

      conn =
        Plug.Test.conn(:post, "/", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer my-token")
        |> Auth.call(auth_opts)
        |> A2A.Plug.call(plug_opts)

      assert conn.status == 200
      result = Jason.decode!(conn.resp_body)
      meta = result["result"]["task"]["metadata"]

      assert meta["a2a.auth"] == %{
               "scheme" => "bearer_auth",
               "identity" => %{"user_id" => "u-1"}
             }
    end
  end

  # -- WWW-Authenticate header -------------------------------------------------

  describe "WWW-Authenticate header" do
    test "bearer scheme includes WWW-Authenticate" do
      opts = auth_opts()
      conn = Plug.Test.conn(:post, "/") |> Auth.call(opts)

      [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ "Bearer"
      assert challenge =~ "a2a"
    end

    test "basic scheme includes WWW-Authenticate" do
      opts =
        auth_opts(
          schemes: %{"basic" => %HTTPAuth{scheme: "basic"}},
          verify: fn _, _, _ -> {:error, "no"} end
        )

      conn = Plug.Test.conn(:post, "/") |> Auth.call(opts)
      [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ "Basic"
      assert challenge =~ "a2a"
    end

    test "API key scheme does not include WWW-Authenticate" do
      opts =
        auth_opts(
          schemes: %{"api_key" => %APIKey{in: "header", name: "X-Api-Key"}},
          verify: fn _, _, _ -> {:error, "no"} end
        )

      conn = Plug.Test.conn(:post, "/") |> Auth.call(opts)
      assert get_resp_header(conn, "www-authenticate") == []
    end

    test "OAuth2 scheme includes Bearer WWW-Authenticate" do
      opts =
        auth_opts(
          schemes: %{"oauth" => %OAuth2{flows: %{}}},
          verify: fn _, _, _ -> {:error, "no"} end
        )

      conn = Plug.Test.conn(:post, "/") |> Auth.call(opts)
      [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ "Bearer"
    end

    test "OpenIDConnect scheme includes Bearer WWW-Authenticate" do
      opts =
        auth_opts(
          schemes: %{
            "oidc" => %OpenIDConnect{open_id_connect_url: "https://example.com"}
          },
          verify: fn _, _, _ -> {:error, "no"} end
        )

      conn = Plug.Test.conn(:post, "/") |> Auth.call(opts)
      [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ "Bearer"
    end

    test "custom realm appears in challenge" do
      opts = auth_opts(realm: "my-agent")
      conn = Plug.Test.conn(:post, "/") |> Auth.call(opts)

      [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ "my-agent"
    end
  end

  # -- Init validation ---------------------------------------------------------

  describe "init validation" do
    test "missing :schemes raises ArgumentError" do
      assert_raise ArgumentError, ~r/requires :schemes/, fn ->
        Auth.init(verify: fn _, _, _ -> :ok end)
      end
    end

    test "empty :schemes raises ArgumentError" do
      assert_raise ArgumentError, ~r/non-empty map/, fn ->
        Auth.init(schemes: %{}, verify: fn _, _, _ -> :ok end)
      end
    end

    test "missing :verify raises ArgumentError" do
      assert_raise ArgumentError, ~r/requires :verify/, fn ->
        Auth.init(schemes: %{"a" => %HTTPAuth{scheme: "bearer"}})
      end
    end

    test "non-function :verify raises ArgumentError" do
      assert_raise ArgumentError, ~r/function with arity 3/, fn ->
        Auth.init(
          schemes: %{"a" => %HTTPAuth{scheme: "bearer"}},
          verify: "not a function"
        )
      end
    end

    test ":security referencing unknown scheme raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown scheme/, fn ->
        Auth.init(
          schemes: %{"a" => %HTTPAuth{scheme: "bearer"}},
          verify: fn _, _, _ -> :ok end,
          security: [%{"nonexistent" => []}]
        )
      end
    end
  end
end
