if Code.ensure_loaded?(Plug) and Code.ensure_loaded?(Joken) do
  defmodule A2A.Plug.JWTVerifier do
    @moduledoc """
    JWT verification utilities for A2A principal authentication.

    Provides JWT verification for authenticating principals (users, agents, or
    services) accessing A2A endpoints. Signature verification is delegated to
    [Joken](https://hex.pm/packages/joken)/JOSE rather than hand-rolled crypto.

    ## Features

    - JWT signature verification via Joken (HS256)
    - Expiration (`exp`) and not-before (`nbf`) validation with clock-skew tolerance
    - Issuer and audience verification
    - Configurable required claims (default: `["sub"]`)

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
    - `:algorithm` — Signature algorithm: "HS256" (default: "HS256")
    - `:issuer` — Expected issuer claim (optional)
    - `:audience` — Expected audience claim (optional)
    - `:required_claims` — List of claim names that must be present (default: `["sub"]`)
    - `:clock_skew` — Allowed clock skew in seconds (default: 60)

    This module is only compiled when both `:plug` and `:joken` are available.
    """

    @type verifier :: %{
            secret: String.t() | nil,
            algorithm: String.t(),
            issuer: String.t() | nil,
            audience: String.t() | nil,
            required_claims: [String.t()],
            clock_skew: non_neg_integer()
          }

    @type claim_map :: %{String.t() => any()}

    @doc """
    Creates a new JWT verifier configuration.

    Accepts a keyword list of options. See the module documentation for
    the full list of supported keys.

    ## Examples

        iex> v = A2A.Plug.JWTVerifier.new(secret: "s3cret")
        iex> v.algorithm
        "HS256"
        iex> v.required_claims
        ["sub"]

        iex> v = A2A.Plug.JWTVerifier.new(secret: "s", issuer: "iss", clock_skew: 120)
        iex> {v.issuer, v.clock_skew}
        {"iss", 120}
    """
    @spec new(keyword()) :: verifier()
    def new(opts) when is_list(opts) do
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

    Performs the following checks in order:

    1. Decodes and validates the JWT header (algorithm match)
    2. Verifies the cryptographic signature via Joken
    3. Validates required claims, issuer, audience, expiration, and not-before

    Returns `{:ok, claims}` on success or `{:error, reason}` with a
    human-readable description of what failed.

    ## Examples

        verifier = A2A.Plug.JWTVerifier.new(secret: "my-secret")

        case A2A.Plug.JWTVerifier.verify(verifier, token) do
          {:ok, claims} -> IO.inspect(claims["sub"])
          {:error, reason} -> IO.puts("Auth failed: \#{reason}")
        end
    """
    @spec verify(verifier(), String.t()) :: {:ok, claim_map()} | {:error, String.t()}
    def verify(config, token) when is_binary(token) do
      with {:ok, header} <- peek_header(token),
           :ok <- verify_algorithm(header, config),
           {:ok, signer} <- build_signer(config),
           {:ok, claims} <- verify_signature(token, signer),
           :ok <- validate_claims(claims, config) do
        {:ok, claims}
      end
    end

    # -- Signature (delegated to Joken) -----------------------------------------

    defp peek_header(token) do
      case Joken.peek_header(token) do
        {:ok, header} -> {:ok, header}
        {:error, _} -> {:error, "invalid JWT format"}
      end
    rescue
      _ -> {:error, "invalid JWT format"}
    end

    defp verify_algorithm(header, config) do
      case Map.get(header, "alg") do
        nil ->
          {:error, "invalid JWT format"}

        alg when alg == config.algorithm ->
          :ok

        alg ->
          {:error, "algorithm mismatch: expected #{config.algorithm}, got #{alg}"}
      end
    end

    defp build_signer(%{secret: nil}),
      do: {:error, "no secret key configured for HMAC verification"}

    defp build_signer(%{algorithm: "HS256", secret: secret}),
      do: {:ok, Joken.Signer.create("HS256", secret)}

    defp build_signer(%{algorithm: algorithm}),
      do: {:error, "unsupported algorithm: #{algorithm}"}

    defp verify_signature(token, signer) do
      case Joken.verify(token, signer) do
        {:ok, claims} -> {:ok, claims}
        {:error, _reason} -> {:error, "signature verification failed"}
      end
    end

    # -- Claims (not security-sensitive crypto) ---------------------------------

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

        exp when is_number(exp) ->
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

        nbf when is_number(nbf) ->
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
