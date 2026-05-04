defmodule A2A.AgentCard.SigningTest do
  use ExUnit.Case, async: true
  alias A2A.AgentCard.Signing
  alias A2A.AgentCard

  setup do
    # Create a test key
    jwk = JOSE.JWK.from(%{"kty" => "oct", "k" => "AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75aKtMN3Yj0iPS4hcgUuTwjAzZr1Z9CAow"})
    
    card = %AgentCard{
      name: "helper",
      description: "A helper agent",
      url: "https://helper.example.com",
      version: "1.0.0",
      skills: [
        %{id: "search", name: "search", description: "", tags: []}
      ]
    }
    
    {:ok, card: card, jwk: jwk}
  end

  test "canonicalize removes empty items and signatures", %{card: card} do
    card_with_sig = %{card | signatures: [%{"signature" => "fake"}]}
    
    canonical = Signing.canonicalize(card_with_sig)
    
    # Should not contain description (empty), should not contain signatures
    refute canonical =~ "description"
    refute canonical =~ "signatures"
    assert canonical =~ "helper"
    assert canonical =~ "search"
    
    # Ensure it parses back as valid JSON
    assert match?({:ok, _}, Jason.decode(canonical))
  end

  test "sign and verify an AgentCard", %{card: card, jwk: jwk} do
    protected_header = %{"alg" => "HS256", "kid" => "test-kid"}
    
    signed_card = Signing.sign(card, jwk, protected_header)
    
    assert is_list(signed_card.signatures)
    assert length(signed_card.signatures) == 1
    
    sig = hd(signed_card.signatures)
    assert Map.has_key?(sig, "protected")
    assert Map.has_key?(sig, "signature")
    
    key_provider = fn 
      "test-kid", _jku -> jwk
      _, _ -> {:error, "Not found"}
    end
    
    assert :ok = Signing.verify(signed_card, key_provider, ["HS256"])
    
    # Try with wrong algorithm
    assert {:error, _} = Signing.verify(signed_card, key_provider, ["RS256"])
    
    # Try with wrong kid
    key_provider_wrong = fn _, _ -> {:error, "Not found"} end
    assert {:error, _} = Signing.verify(signed_card, key_provider_wrong, ["HS256"])
  end

  test "verify fails if card is modified", %{card: card, jwk: jwk} do
    protected_header = %{"alg" => "HS256", "kid" => "test-kid"}
    signed_card = Signing.sign(card, jwk, protected_header)
    
    tampered_card = %{signed_card | name: "hacker"}
    
    key_provider = fn "test-kid", _ -> jwk end
    
    assert {:error, _} = Signing.verify(tampered_card, key_provider, ["HS256"])
  end
end
