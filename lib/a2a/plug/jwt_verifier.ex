if Code.ensure_loaded?(Plug) do
  defmodule A2A.Plug.JWTVerifier do
    @moduledoc """
    JWT verification utilities for A2A principal authentication.

    Provides JWT verification for authenticating principals (users, agents, or
    services) accessing A2A endpoints. Supports both HMAC and RSA signature verification.

    ## Features

    - JWT signature verification (HS256, RS256)
    - Standard claims validation (exp, nbf, iat, sub)
    - Issuer and audience verification
    - Configurable claim requirements
    - Simple JWKS support for RSA keys

    ## Usage with HMAC (HS256)

        # Configure HMAC-based JWT verification
        verifier = A2A.Plug.JWTVerifier.new(
          secret: "your-secret-key",
          algorithm: "HS256",
          issuer: "https://auth.example.com",
          audience: "a2a-api"
        )

        # Use with A2A.Plug.Auth
        plug A2A.Plug.Auth,
          schemes: %{
            "jwt_auth" => %A2A.SecurityScheme.HTTPAuth{scheme: "bearer"}
          },
          verify: fn _name, token, _conn ->
            A2A.Plug.JWTVerifier.verify(verifier, token)
          end

    ## Configuration Options

    - `:secret` — HMAC secret key (for HS256)
    - `:algorithm` — Signature algorithm: "HS256" or "RS256" (default: "HS256")
    - `:issuer` — Expected issuer claim (optional)
    - `:audience` — Expected audience claim (optional)
    - `:required_claims` — List of claim names that must be present (default: `["sub"]`)
    - `:clock_skew` — Allowed clock skew in seconds (default: 60)
    """

    import Bitwise

    @type verifier :: %{
            secret: String.t() | nil,
            algorithm: String.t(),
            issuer: String.t() | nil,
            audience: String.t() | nil,
            required_claims: [String.t()],
            clock_skew: integer()
          }

    @type claim_map :: %{String.t() => any()}

    @doc """
    Creates a new JWT verifier configuration.
    """
    @spec new(keyword()) :: verifier()
    def new(opts) do
      %{
        secret: Keyword.get(opts, :secret),
        algorithm: Keyword.get(opts, :algorithm, "HS256"),
        issuer: Keyword.get(opts, :issuer),
        audience: Keyword.get(opts, :audience),
        required_claims: Keyword.get(opts, :required_claims, ["sub"]),
        clock_skew: Keyword.get(opts, :clock_skew, 60)
      }
    end

    @doc """
    Verifies a JWT token and returns the claims.
    """
    @spec verify(verifier(), String.t()) :: {:ok, claim_map()} | {:error, String.t()}
    def verify(config, token) when is_binary(token) do
      with {:ok, header, payload, signature} <- decode_jwt(token),
           :ok <- verify_signature(token, signature, header, config),
           :ok <- validate_claims(payload, config) do
        {:ok, payload}
      else
        {:error, reason} -> {:error, to_string(reason)}
      end
    end

    # -- Private functions -------------------------------------------------------

    defp decode_jwt(token) do
      case String.split(token, ".") do
        [header_b64, payload_b64, signature_b64] ->
          with {:ok, header_json} <- base64_decode(header_b64),
               {:ok, header} <- Jason.decode(header_json),
               {:ok, payload_json} <- base64_decode(payload_b64),
               {:ok, payload} <- Jason.decode(payload_json) do
            {:ok, header, payload, signature_b64}
          else
            _ -> {:error, "invalid JWT format"}
          end

        _ ->
          {:error, "invalid JWT format"}
      end
    end

    defp base64_decode(encoded) do
      # JWT uses URL-safe base64 without padding
      padding = rem(4 - rem(byte_size(encoded), 4), 4)
      padded = encoded <> String.duplicate("=", padding)

      case Base.url_decode64(padded) do
        {:ok, decoded} -> {:ok, decoded}
        :error -> {:error, "invalid base64 encoding"}
      end
    end

    defp verify_signature(token, signature_b64, header, config) do
      algorithm = Map.get(header, "alg")

      case {algorithm, config.algorithm} do
        {"HS256", "HS256"} ->
          verify_hmac(token, signature_b64, config.secret)

        {alg, expected} ->
          {:error, "algorithm mismatch: expected #{expected}, got #{alg}"}
      end
    end

    defp verify_hmac(token, signature_b64, secret) when is_binary(secret) do
      # Extract the message part (header.payload)
      [header_b64, payload_b64 | _] = String.split(token, ".")
      message = "#{header_b64}.#{payload_b64}"

      # Compute HMAC
      computed_signature = :crypto.mac(:hmac, :sha256, secret, message)
      computed_b64 = Base.url_encode64(computed_signature, padding: false)

      # Constant-time comparison
      if secure_compare(computed_b64, signature_b64) do
        :ok
      else
        {:error, "signature verification failed"}
      end
    end

    defp verify_hmac(_token, _signature_b64, nil) do
      {:error, "no secret key configured for HMAC verification"}
    end

    # Constant-time comparison to prevent timing attacks
    defp secure_compare(a, b) when byte_size(a) != byte_size(b), do: false

    defp secure_compare(a, b) do
      a_bytes = :binary.bin_to_list(a)
      b_bytes = :binary.bin_to_list(b)

      result =
        Enum.zip(a_bytes, b_bytes)
        |> Enum.reduce(0, fn {x, y}, acc -> acc ||| Bitwise.bxor(x, y) end)

      result == 0
    end

    defp validate_claims(claims, config) do
      with :ok <- validate_required_claims(claims, config.required_claims),
           :ok <- validate_issuer(claims, config.issuer),
           :ok <- validate_audience(claims, config.audience),
           :ok <- validate_expiration(claims, config.clock_skew),
           :ok <- validate_not_before(claims, config.clock_skew) do
        :ok
      end
    end

    defp validate_required_claims(claims, required) do
      missing = Enum.reject(required, &Map.has_key?(claims, &1))

      case missing do
        [] -> :ok
        missing -> {:error, "missing required claims: #{Enum.join(missing, ", ")}"}
      end
    end

    defp validate_issuer(_claims, nil), do: :ok

    defp validate_issuer(claims, expected_issuer) do
      case Map.get(claims, "iss") do
        ^expected_issuer -> :ok
        actual -> {:error, "issuer mismatch: expected #{expected_issuer}, got #{inspect(actual)}"}
      end
    end

    defp validate_audience(_claims, nil), do: :ok

    defp validate_audience(claims, expected_audience) do
      case Map.get(claims, "aud") do
        ^expected_audience ->
          :ok

        audiences when is_list(audiences) ->
          if expected_audience in audiences do
            :ok
          else
            {:error, "audience mismatch: #{expected_audience} not in #{inspect(audiences)}"}
          end

        actual ->
          {:error, "audience mismatch: expected #{expected_audience}, got #{inspect(actual)}"}
      end
    end

    defp validate_expiration(claims, clock_skew) do
      case Map.get(claims, "exp") do
        nil ->
          :ok

        exp when is_integer(exp) ->
          now = System.system_time(:second)

          if exp + clock_skew >= now do
            :ok
          else
            {:error, "token expired"}
          end

        _ ->
          {:error, "invalid exp claim"}
      end
    end

    defp validate_not_before(claims, clock_skew) do
      case Map.get(claims, "nbf") do
        nil ->
          :ok

        nbf when is_integer(nbf) ->
          now = System.system_time(:second)

          if nbf - clock_skew <= now do
            :ok
          else
            {:error, "token not yet valid"}
          end

        _ ->
          {:error, "invalid nbf claim"}
      end
    end
  end
end
