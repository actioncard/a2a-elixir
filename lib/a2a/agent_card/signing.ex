defmodule A2A.AgentCard.Signing do
  @moduledoc """
  JWS (RFC 7515) detached-payload signing and verification for `A2A.AgentCard`.

  AgentCard signatures use the JSON Serialization form of JWS with a *detached*
  payload: the payload is the canonical JSON encoding of the card (with empty
  fields and any existing `signatures` removed), and is therefore not carried in
  the signature object itself. Each entry in `card.signatures` is a map with:

    * `"protected"` — base64url-encoded protected JWS header (contains `alg`,
      and typically `kid`)
    * `"signature"` — base64url-encoded signature
    * `"header"` — optional unprotected header (currently unused)

  Requires the optional `:jose` dependency. Guarded with `Code.ensure_loaded?/1`
  so the rest of the library compiles and runs without it.

  ## Example

      jwk = JOSE.JWK.generate_key({:oct, 32})
      signed = A2A.AgentCard.Signing.sign(card, jwk, %{"alg" => "HS256", "kid" => "k1"})

      key_provider = fn "k1", _jku -> jwk; _, _ -> {:error, :unknown_kid} end
      :ok = A2A.AgentCard.Signing.verify(signed, key_provider, ["HS256"])
  """

  alias A2A.AgentCard

  @typedoc """
  Resolves a key id (`kid`) and optional JWK Set URL (`jku`) to a JWK.

  Returns the JWK directly, `{:ok, jwk}`, or `{:error, reason}` when the key is
  unknown.
  """
  @type key_provider ::
          (String.t() | nil, String.t() | nil ->
             JOSE.JWK.t() | {:ok, JOSE.JWK.t()} | {:error, term()})

  @doc """
  Produces the canonical JSON string used as the signing payload for a card.

  Empty values (`nil`, `""`, `[]`, `%{}`) are dropped, the `signatures` field is
  removed, and the remaining keys are emitted in a stable (sorted) order so that
  signing and verification operate on byte-identical input.
  """
  @spec canonicalize(AgentCard.t()) :: String.t()
  def canonicalize(%AgentCard{} = card) do
    card
    |> AgentCard.to_map()
    |> Map.delete("signatures")
    |> prune()
    |> encode_canonical()
  end

  @doc """
  Signs `card` with `jwk` under the given protected header and appends the
  resulting JWS signature object to `card.signatures`.

  The protected header must contain an `"alg"`; `"kid"` is strongly recommended
  so verifiers can resolve the right key. Existing signatures are preserved.
  """
  @spec sign(AgentCard.t(), JOSE.JWK.t(), map()) :: AgentCard.t()
  def sign(%AgentCard{} = card, jwk, protected_header) when is_map(protected_header) do
    ensure_jose!()

    payload = canonicalize(card)

    {_modules, %{"protected" => protected, "signature" => signature}} =
      jwk
      |> JOSE.JWS.sign(payload, protected_header)
      |> JOSE.JWS.compact()
      |> then(fn {mods, compact} -> {mods, split_detached(compact)} end)

    sig = %{"protected" => protected, "signature" => signature}
    %{card | signatures: card.signatures ++ [sig]}
  end

  @doc """
  Verifies every signature on `signed_card`.

  For each signature the protected header is decoded, its `alg` checked against
  `allowed_algs`, the verification key resolved via `key_provider` (keyed on the
  header's `kid`/`jku`), and the JWS verified against the canonical payload of
  the card. Returns `:ok` only when *all* signatures verify; otherwise
  `{:error, reason}`. A card with no signatures is an error.
  """
  @spec verify(AgentCard.t(), key_provider(), [String.t()]) :: :ok | {:error, term()}
  def verify(%AgentCard{signatures: []}, _key_provider, _allowed_algs),
    do: {:error, :no_signatures}

  def verify(%AgentCard{} = signed_card, key_provider, allowed_algs)
      when is_function(key_provider, 2) and is_list(allowed_algs) do
    ensure_jose!()

    payload = canonicalize(signed_card)

    Enum.reduce_while(signed_card.signatures, :ok, fn sig, _acc ->
      case verify_one(sig, payload, key_provider, allowed_algs) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # --- internals -----------------------------------------------------------

  defp verify_one(sig, payload, key_provider, allowed_algs) do
    protected = fetch_field(sig, "protected")
    signature = fetch_field(sig, "signature")

    with {:protected, p} when is_binary(p) <- {:protected, protected},
         {:signature, s} when is_binary(s) <- {:signature, signature},
         {:ok, header} <- decode_protected(p),
         {:ok, alg} <- check_alg(header, allowed_algs),
         {:ok, jwk} <- resolve_key(key_provider, header) do
      compact = p <> "." <> base64url(payload) <> "." <> s

      case JOSE.JWS.verify_strict(JOSE.JWK.from(jwk), [alg], compact) do
        {true, _payload, _jws} -> :ok
        {false, _payload, _jws} -> {:error, :signature_invalid}
        other -> {:error, {:verify_failed, other}}
      end
    else
      {:protected, _} -> {:error, :missing_protected}
      {:signature, _} -> {:error, :missing_signature}
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, {:verify_exception, Exception.message(e)}}
  end

  defp decode_protected(protected) do
    with {:ok, json} <- base64url_decode(protected),
         {:ok, header} <- Jason.decode(json) do
      {:ok, header}
    else
      _ -> {:error, :bad_protected_header}
    end
  end

  defp check_alg(header, allowed_algs) do
    case Map.get(header, "alg") do
      nil -> {:error, :missing_alg}
      alg -> if alg in allowed_algs, do: {:ok, alg}, else: {:error, {:alg_not_allowed, alg}}
    end
  end

  defp resolve_key(key_provider, header) do
    case key_provider.(Map.get(header, "kid"), Map.get(header, "jku")) do
      {:error, _} = err -> err
      {:ok, jwk} -> {:ok, jwk}
      nil -> {:error, :key_not_found}
      jwk -> {:ok, jwk}
    end
  end

  # Drop the detached payload segment from a compact JWS ("header..signature"
  # has an empty middle), yielding the protected header and signature.
  defp split_detached(compact) do
    [protected, _payload, signature] = String.split(compact, ".", parts: 3)
    %{"protected" => protected, "signature" => signature}
  end

  defp fetch_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  # Recursively prune empty values so the canonical form omits absent fields.
  defp prune(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {k, v} -> {k, prune(v)} end)
    |> Enum.reject(fn {_k, v} -> empty?(v) end)
    |> Map.new()
  end

  defp prune(value) when is_list(value), do: Enum.map(value, &prune/1)
  defp prune(value), do: value

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(map) when map_size(map) == 0, do: true
  defp empty?(_), do: false

  # Stable JSON: sort map keys at every level so output is deterministic.
  defp encode_canonical(value), do: value |> to_canonical() |> Jason.encode!()

  defp to_canonical(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {k, v} -> {to_string(k), to_canonical(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp to_canonical(value) when is_list(value), do: Enum.map(value, &to_canonical/1)
  defp to_canonical(value), do: value

  defp base64url(data), do: Base.url_encode64(data, padding: false)

  defp base64url_decode(data) do
    case Base.url_decode64(data, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.url_decode64(pad(data))
    end
  end

  defp pad(data) do
    case rem(byte_size(data), 4) do
      0 -> data
      n -> data <> String.duplicate("=", 4 - n)
    end
  end

  defp ensure_jose! do
    unless Code.ensure_loaded?(JOSE.JWS) do
      raise """
      A2A.AgentCard.Signing requires the optional :jose dependency.
      Add `{:jose, "~> 1.11"}` to your deps.
      """
    end
  end
end
