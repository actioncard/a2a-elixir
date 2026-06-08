defmodule A2A.Plug.JWTVerifierTest do
  use ExUnit.Case, async: true

  @moduletag :plug

  alias A2A.Plug.JWTVerifier

  # Test secret for HMAC signing
  @test_secret "test-secret-key-that-is-long-enough"

  # -- Helpers -----------------------------------------------------------------

  defp create_jwt_token(payload, secret \\\\ @test_secret) do
    header = %{"alg" => "HS256", "typ" => "JWT"}
    header_json = Jason.encode!(header)
    payload_json = Jason.encode!(payload)

    header_b64 = Base.url_encode64(header_json, padding: false)
    payload_b64 = Base.url_encode64(payload_json, padding: false)
    message = "#{header_b64}.#{payload_b64}"

    signature = :crypto.mac(:hmac, :sha256, secret, message)
    signature_b64 = Base.url_encode64(signature, padding: false)

    "#{message}.#{signature_b64}"
  end

  defp future_timestamp, do: System.system_time(:second) + 3600
  defp past_timestamp, do: System.system_time(:second) - 3600
  defp current_timestamp, do: System.system_time(:second)

  # -- Configuration -----------------------------------------------------------

  describe "new/1" do
    test "creates verifier with default options" do
      verifier = JWTVerifier.new(secret: @test_secret)

      assert verifier.secret == @test_secret
      assert verifier.algorithm == "HS256"
      assert verifier.issuer == nil
      assert verifier.audience == nil
      assert verifier.required_claims == ["sub"]
      assert verifier.clock_skew == 60
    end

    test "creates verifier with custom options" do
      verifier =
        JWTVerifier.new(
          secret: "custom-secret",
          algorithm: "HS256",
          issuer: "https://auth.example.com",
          audience: "test-api",
          required_claims: ["sub", "role"],
          clock_skew: 120
        )

      assert verifier.secret == "custom-secret"
      assert verifier.algorithm == "HS256"
      assert verifier.issuer == "https://auth.example.com"
      assert verifier.audience == "test-api"
      assert verifier.required_claims == ["sub", "role"]
      assert verifier.clock_skew == 120
    end
  end

  # -- Token verification -----------------------------------------------------

  describe "verify/2" do
    test "verifies valid JWT with required claims" do
      verifier = JWTVerifier.new(secret: @test_secret)

      payload = %{
        "sub" => "user123",
        "iss" => "test-issuer",
        "aud" => "test-audience",
        "exp" => future_timestamp(),
        "iat" => current_timestamp()
      }

      token = create_jwt_token(payload)

      assert {:ok, claims} = JWTVerifier.verify(verifier, token)
      assert claims["sub"] == "user123"
      assert claims["iss"] == "test-issuer"
    end

    test "verifies valid JWT with principal claims" do
      verifier =
        JWTVerifier.new(
          secret: @test_secret,
          required_claims: ["sub", "principal_type"]
        )

      payload = %{
        "sub" => "alice@example.com",
        "principal_type" => "user",
        "iss" => "https://auth.example.com",
        "aud" => "a2a-api",
        "exp" => future_timestamp(),
        "iat" => current_timestamp(),
        "roles" => ["user", "api-access"]
      }

      token = create_jwt_token(payload)

      assert {:ok, claims} = JWTVerifier.verify(verifier, token)
      assert claims["sub"] == "alice@example.com"
      assert claims["principal_type"] == "user"
      assert claims["roles"] == ["user", "api-access"]
    end

    test "rejects token with invalid signature" do
      verifier = JWTVerifier.new(secret: @test_secret)

      payload = %{
        "sub" => "user123",
        "exp" => future_timestamp()
      }

      # Create token with wrong secret
      token = create_jwt_token(payload, "wrong-secret")

      assert {:error, reason} = JWTVerifier.verify(verifier, token)
      assert reason =~ "signature verification failed"
    end

    test "rejects expired token" do
      verifier = JWTVerifier.new(secret: @test_secret)

      payload = %{
        "sub" => "user123",
        "exp" => past_timestamp()
      }

      token = create_jwt_token(payload)

      assert {:error, "token expired"} = JWTVerifier.verify(verifier, token)
    end

    test "accepts token within clock skew" do
      verifier = JWTVerifier.new(secret: @test_secret, clock_skew: 300)

      # Token expired 2 minutes ago, but within 5-minute clock skew
      payload = %{
        "sub" => "user123",
        "exp" => current_timestamp() - 120
      }

      token = create_jwt_token(payload)

      assert {:ok, _claims} = JWTVerifier.verify(verifier, token)
    end

    test "rejects token not yet valid (nbf)" do
      verifier = JWTVerifier.new(secret: @test_secret)

      payload = %{
        "sub" => "user123",
        "exp" => future_timestamp(),
        "nbf" => future_timestamp()
      }

      token = create_jwt_token(payload)

      assert {:error, "token not yet valid"} = JWTVerifier.verify(verifier, token)
    end

    test "rejects token missing required claims" do
      verifier =
        JWTVerifier.new(
          secret: @test_secret,
          required_claims: ["sub", "role"]
        )

      payload = %{
        "sub" => "user123",
        "exp" => future_timestamp()
        # Missing "role" claim
      }

      token = create_jwt_token(payload)

      assert {:error, reason} = JWTVerifier.verify(verifier, token)
      assert reason =~ "missing required claims: role"
    end

    test "validates issuer when configured" do
      verifier =
        JWTVerifier.new(
          secret: @test_secret,
          issuer: "https://auth.example.com"
        )

      payload = %{
        "sub" => "user123",
        "iss" => "https://wrong-issuer.com",
        "exp" => future_timestamp()
      }

      token = create_jwt_token(payload)

      assert {:error, reason} = JWTVerifier.verify(verifier, token)
      assert reason =~ "issuer mismatch"
    end

    test "validates audience when configured" do
      verifier =
        JWTVerifier.new(
          secret: @test_secret,
          audience: "a2a-api"
        )

      payload = %{
        "sub" => "user123",
        "aud" => "wrong-audience",
        "exp" => future_timestamp()
      }

      token = create_jwt_token(payload)

      assert {:error, reason} = JWTVerifier.verify(verifier, token)
      assert reason =~ "audience mismatch"
    end

    test "validates audience from list when configured" do
      verifier =
        JWTVerifier.new(
          secret: @test_secret,
          audience: "a2a-api"
        )

      payload = %{
        "sub" => "user123",
        "aud" => ["web-api", "a2a-api", "mobile-api"],
        "exp" => future_timestamp()
      }

      token = create_jwt_token(payload)

      assert {:ok, _claims} = JWTVerifier.verify(verifier, token)
    end

    test "rejects malformed JWT" do
      verifier = JWTVerifier.new(secret: @test_secret)

      assert {:error, reason} = JWTVerifier.verify(verifier, "invalid.jwt")
      assert reason =~ "invalid JWT format"
    end

    test "rejects JWT with invalid base64" do
      verifier = JWTVerifier.new(secret: @test_secret)

      # Invalid base64 in header
      invalid_token = "invalid-base64!!!.eyJzdWIiOiJ1c2VyMTIzIn0.signature"

      assert {:error, reason} = JWTVerifier.verify(verifier, invalid_token)
      assert reason =~ "invalid"
    end

    test "rejects JWT with invalid JSON" do
      verifier = JWTVerifier.new(secret: @test_secret)

      # Valid base64 but invalid JSON
      header_b64 = Base.url_encode64("not-json", padding: false)
      payload_b64 = Base.url_encode64("{\"sub\":\"test\"}", padding: false)
      token = "#{header_b64}.#{payload_b64}.signature"

      assert {:error, reason} = JWTVerifier.verify(verifier, token)
      assert reason =~ "invalid JWT format"
    end

    test "rejects JWT with algorithm mismatch" do
      verifier = JWTVerifier.new(secret: @test_secret, algorithm: "HS256")

      # Create token with RS256 in header
      header = %{"alg" => "RS256", "typ" => "JWT"}
      payload = %{"sub" => "user123", "exp" => future_timestamp()}

      header_json = Jason.encode!(header)
      payload_json = Jason.encode!(payload)

      header_b64 = Base.url_encode64(header_json, padding: false)
      payload_b64 = Base.url_encode64(payload_json, padding: false)
      
      # Use dummy signature since verification will fail on algorithm check
      token = "#{header_b64}.#{payload_b64}.dummy-signature"

      assert {:error, reason} = JWTVerifier.verify(verifier, token)
      assert reason =~ "algorithm mismatch"
    end
  end

  # -- Integration scenarios --------------------------------------------------

  describe "integration scenarios" do
    test "principal authentication flow" do
      verifier =
        JWTVerifier.new(
          secret: @test_secret,
          issuer: "https://auth.example.com",
          audience: "a2a-api",
          required_claims: ["sub", "principal_type"]
        )

      # User principal
      user_payload = %{
        "sub" => "alice@example.com",
        "principal_type" => "user",
        "iss" => "https://auth.example.com",
        "aud" => "a2a-api",
        "exp" => future_timestamp(),
        "iat" => current_timestamp(),
        "roles" => ["user", "api-access"],
        "permissions" => ["message:send", "task:read"]
      }

      user_token = create_jwt_token(user_payload)

      assert {:ok, claims} = JWTVerifier.verify(verifier, user_token)
      assert claims["sub"] == "alice@example.com"
      assert claims["principal_type"] == "user"
      assert claims["roles"] == ["user", "api-access"]

      # Agent principal
      agent_payload = %{
        "sub" => "agent-123",
        "principal_type" => "agent",
        "iss" => "https://auth.example.com",
        "aud" => "a2a-api",
        "exp" => future_timestamp(),
        "iat" => current_timestamp(),
        "agent_id" => "agent-123",
        "capabilities" => ["message:process", "task:execute"]
      }

      agent_token = create_jwt_token(agent_payload)

      assert {:ok, claims} = JWTVerifier.verify(verifier, agent_token)
      assert claims["sub"] == "agent-123"
      assert claims["principal_type"] == "agent"
      assert claims["agent_id"] == "agent-123"
    end

    test "default-to-test gap closure" do
      # Test mode: simple secret-based validation
      test_verifier =
        JWTVerifier.new(
          secret: "test-secret",
          algorithm: "HS256"
        )

      # Production mode: with full validation
      prod_verifier =
        JWTVerifier.new(
          secret: "production-secret",
          algorithm: "HS256",
          issuer: "https://prod-auth.example.com",
          audience: "a2a-production",
          required_claims: ["sub", "principal_type", "roles"]
        )

      # Both should work with appropriately configured tokens
      test_payload = %{
        "sub" => "test-user",
        "exp" => future_timestamp()
      }

      prod_payload = %{
        "sub" => "prod-user",
        "principal_type" => "user",
        "iss" => "https://prod-auth.example.com",
        "aud" => "a2a-production",
        "exp" => future_timestamp(),
        "roles" => ["admin"]
      }

      test_token = create_jwt_token(test_payload, "test-secret")
      prod_token = create_jwt_token(prod_payload, "production-secret")

      assert {:ok, _} = JWTVerifier.verify(test_verifier, test_token)
      assert {:ok, _} = JWTVerifier.verify(prod_verifier, prod_token)

      # Cross-verification should fail
      assert {:error, _} = JWTVerifier.verify(test_verifier, prod_token)
      assert {:error, _} = JWTVerifier.verify(prod_verifier, test_token)
    end
  end
end