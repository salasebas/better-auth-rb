# frozen_string_literal: true

require "json"
require_relative "../../test_helper"

class OAuthProviderIssuerPathMetadataTest < Minitest::Test
  include OAuthProviderFlowHelpers

  ISSUER = "http://localhost:3000/api/auth/tenant"

  def test_issuer_path_well_known_aliases_return_metadata
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: :memory,
      email_and_password: {enabled: true},
      plugins: [
        BetterAuth::Plugins.jwt(jwks: {key_pair_config: {alg: "EdDSA"}}, jwt: {issuer: ISSUER}),
        BetterAuth::Plugins.oauth_provider(
          scopes: ["openid"],
          allow_dynamic_client_registration: true,
          issuer_path: "/api/auth/tenant"
        )
      ]
    )

    default_metadata = auth.api.get_openid_config
    expected_issuer = default_metadata[:issuer]

    status, _headers, body = auth.handler.call(
      rack_env("GET", "/api/auth/.well-known/oauth-authorization-server/api/auth/tenant")
    )
    payload = JSON.parse(body.join, symbolize_names: true)
    assert_equal 200, status
    assert_equal expected_issuer, payload[:issuer]

    status, _headers, body = auth.handler.call(
      rack_env("GET", "/api/auth/tenant/.well-known/openid-configuration")
    )
    openid_payload = JSON.parse(body.join, symbolize_names: true)
    assert_equal 200, status
    assert_equal expected_issuer, openid_payload[:issuer]
  end
end
