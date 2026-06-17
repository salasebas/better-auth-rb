# frozen_string_literal: true

require "jwt"
require_relative "../../test_helper"

class OAuthProviderClientResourceTest < Minitest::Test
  include OAuthProviderFlowHelpers

  ClientResource = BetterAuth::Plugins::OAuthProvider::ClientResource

  def test_protected_resource_metadata_builds_document
    metadata = ClientResource.protected_resource_metadata(
      {scopes_supported: ["read"], bearer_methods_supported: ["header"]},
      authorization_server: "https://auth.example.com",
      oauth_provider_options: {scopes: ["read"]}
    )

    assert_equal "https://auth.example.com", metadata[:resource]
    assert_equal ["https://auth.example.com"], metadata[:authorization_servers]
    assert_equal ["read"], metadata[:scopes_supported]
    assert_equal ["header"], metadata[:bearer_methods_supported]
  end

  def test_protected_resource_metadata_requires_resource
    error = assert_raises(BetterAuth::Error) do
      ClientResource.protected_resource_metadata({}, authorization_server: nil)
    end

    assert_match(/missing required resource/, error.message)
  end

  def test_validate_resource_scopes_rejects_openid
    error = assert_raises(BetterAuth::Error) do
      ClientResource.validate_resource_scopes!(["openid"], {scopes: ["read"]}, [])
    end

    assert_match(/openid scope/, error.message)
  end

  def test_validate_resource_scopes_rejects_unknown_external_scope
    error = assert_raises(BetterAuth::Error) do
      ClientResource.validate_resource_scopes!(["custom:read"], {scopes: ["read"]}, [])
    end

    assert_match(/Unsupported scope custom:read/, error.message)
  end

  def test_verify_access_token_accepts_valid_jwt
    auth = build_auth(scopes: ["read"])
    cookie = sign_up_cookie(auth, email: "resource-client@example.com")
    client = create_client(auth, cookie, grant_types: ["client_credentials"], response_types: [], scope: "read")
    audience = "http://localhost:3000"

    tokens = auth.api.oauth2_token(
      body: {
        grant_type: "client_credentials",
        client_id: client[:client_id],
        client_secret: client[:client_secret],
        scope: "read",
        resource: audience
      }
    )

    payload = ClientResource.verify_access_token(
      tokens[:access_token],
      verify_options: {audience: audience, issuer: "http://localhost:3000"},
      scopes: ["read"],
      ctx: build_endpoint_context(auth)
    )

    assert tokens[:access_token]
    refute_nil payload["sub"] || payload[:sub] || payload["azp"] || payload[:azp]
  end

  def test_verify_access_token_rejects_insufficient_scope
    auth = build_auth(scopes: ["read", "write"])
    cookie = sign_up_cookie(auth, email: "resource-scope@example.com")
    client = create_client(auth, cookie, grant_types: ["client_credentials"], response_types: [], scope: "read")
    audience = "http://localhost:3000"
    tokens = auth.api.oauth2_token(
      body: {
        grant_type: "client_credentials",
        client_id: client[:client_id],
        client_secret: client[:client_secret],
        scope: "read",
        resource: audience
      }
    )

    error = assert_raises(BetterAuth::APIError) do
      ClientResource.verify_access_token(
        tokens[:access_token],
        verify_options: {audience: audience, issuer: "http://localhost:3000"},
        scopes: ["write"],
        ctx: build_endpoint_context(auth)
      )
    end

    assert_equal 403, error.status_code
  end

  def test_verify_access_token_remote_introspection
    token = "opaque-token"

    ClientResource.stub(:remote_introspect, {"active" => true, "scope" => "read", "sub" => "user-1"}) do
      payload = ClientResource.verify_access_token(
        token,
        verify_options: {audience: "https://api.example.com", issuer: "https://auth.example.com"},
        remote_verify: {
          introspect_url: "https://auth.example.com/oauth2/introspect",
          client_id: "introspect-client",
          client_secret: "secret"
        },
        jwks_url: nil
      )

      assert_equal "user-1", payload["sub"]
      assert_equal "read", payload["scope"]
    end
  end

  private

  def build_endpoint_context(auth)
    BetterAuth::Endpoint::Context.new(
      path: "/oauth2/token",
      method: "POST",
      query: {},
      body: {},
      params: {},
      headers: {},
      context: auth.context
    )
  end
end
