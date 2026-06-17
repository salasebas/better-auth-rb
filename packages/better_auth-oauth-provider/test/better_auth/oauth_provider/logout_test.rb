# frozen_string_literal: true

require_relative "../../test_helper"

class OAuthProviderLogoutTest < Minitest::Test
  include OAuthProviderFlowHelpers

  def test_end_session_returns_success_without_redirect_for_valid_id_token
    auth = build_auth(scopes: ["openid"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid", enable_end_session: true, skip_consent: true)
    tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid")

    response = auth.api.oauth2_end_session(query: {id_token_hint: tokens[:id_token]})

    assert_equal({status: true}, response)
  end

  def test_end_session_accepts_id_token_signed_by_jwt_plugin
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: :memory,
      email_and_password: {enabled: true},
      plugins: [
        BetterAuth::Plugins.jwt(jwks: {key_pair_config: {alg: "EdDSA"}}),
        BetterAuth::Plugins.oauth_provider(scopes: ["openid"], allow_dynamic_client_registration: true)
      ]
    )
    cookie = sign_up_cookie(auth, email: "jwt-id-token@example.com")
    client = create_client(auth, cookie, scope: "openid", enable_end_session: true, skip_consent: true)

    tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid")
    _payload, header = JWT.decode(tokens[:id_token], nil, false)
    response = auth.api.oauth2_end_session(query: {id_token_hint: tokens[:id_token]})

    assert_equal "EdDSA", header["alg"]
    assert_equal({status: true}, response)
  end
end
