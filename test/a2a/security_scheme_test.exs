defmodule A2A.SecuritySchemeTest do
  use ExUnit.Case, async: true

  alias A2A.SecurityScheme.{APIKey, HTTPAuth, OAuth2, OpenIDConnect, MutualTLS}

  describe "APIKey" do
    test "constructs with required fields" do
      scheme = %APIKey{name: "x-api-key", in: "header"}
      assert scheme.name == "x-api-key"
      assert scheme.in == "header"
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn -> struct!(APIKey, []) end
    end
  end

  describe "HTTPAuth" do
    test "constructs with required fields" do
      scheme = %HTTPAuth{scheme: "bearer"}
      assert scheme.scheme == "bearer"
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn -> struct!(HTTPAuth, []) end
    end
  end

  describe "OAuth2" do
    test "constructs with required fields" do
      scheme = %OAuth2{flows: %{"authorizationCode" => %{}}}
      assert scheme.flows == %{"authorizationCode" => %{}}
      assert scheme.oauth2_metadata_url == nil
    end

    test "accepts optional oauth2_metadata_url" do
      scheme = %OAuth2{
        flows: %{},
        oauth2_metadata_url: "https://auth.example.com/.well-known/oauth-authorization-server"
      }

      assert scheme.oauth2_metadata_url ==
               "https://auth.example.com/.well-known/oauth-authorization-server"
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn -> struct!(OAuth2, []) end
    end
  end

  describe "OpenIDConnect" do
    test "constructs with required fields" do
      scheme = %OpenIDConnect{
        open_id_connect_url: "https://auth.example.com/.well-known/openid-configuration"
      }

      assert scheme.open_id_connect_url ==
               "https://auth.example.com/.well-known/openid-configuration"
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn -> struct!(OpenIDConnect, []) end
    end
  end

  describe "MutualTLS" do
    test "constructs with no fields" do
      scheme = %MutualTLS{}
      assert %MutualTLS{} = scheme
    end
  end
end
