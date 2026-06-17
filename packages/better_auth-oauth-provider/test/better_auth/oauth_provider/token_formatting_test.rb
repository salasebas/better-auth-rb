# frozen_string_literal: true

require_relative "../../test_helper"

class OAuthProviderTokenFormattingTest < Minitest::Test
  include OAuthProviderFlowHelpers

  def test_format_refresh_token_encrypt_decrypt_round_trip
    encrypted = nil
    auth = build_auth(
      scopes: ["openid", "offline_access"],
      format_refresh_token: {
        encrypt: ->(token, session_id) {
          encrypted = "enc:#{token}:#{session_id}"
          encrypted
        },
        decrypt: ->(value) {
          _prefix, token, _session = value.split(":", 3)
          token
        }
      }
    )
    cookie = sign_up_cookie(auth, email: "refresh-format@example.com")
    client = create_client(auth, cookie, scope: "openid offline_access", skip_consent: true)
    tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid offline_access")

    assert tokens[:refresh_token].include?("enc:")
    refreshed = auth.api.oauth2_token(body: refresh_grant_body(client, tokens[:refresh_token], scope: "openid"))
    assert refreshed[:access_token]
  end

  def test_custom_generate_refresh_token_is_used
    auth = build_auth(
      scopes: ["openid", "offline_access"],
      generate_refresh_token: -> { "fixed-refresh-token-value" }
    )
    cookie = sign_up_cookie(auth, email: "custom-refresh@example.com")
    client = create_client(auth, cookie, scope: "openid offline_access", skip_consent: true)
    tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid offline_access")

    assert tokens[:refresh_token]
    active = auth.api.oauth2_introspect(body: introspect_body(client, tokens[:refresh_token], hint: "refresh_token"))
    assert_equal true, active[:active]
  end

  def test_custom_generate_opaque_access_token_for_client_credentials
    auth = build_auth(
      scopes: ["read"],
      generate_opaque_access_token: -> { "fixed-access-token-value" }
    )
    cookie = sign_up_cookie(auth, email: "custom-access@example.com")
    client = create_client(auth, cookie, grant_types: ["client_credentials"], response_types: [], scope: "read")

    tokens = auth.api.oauth2_token(
      body: {
        grant_type: "client_credentials",
        client_id: client[:client_id],
        client_secret: client[:client_secret],
        scope: "read"
      }
    )

    assert_equal "ba_at_fixed-access-token-value", tokens[:access_token]
  end

  def test_oauth_protocol_encode_and_decode_refresh_token_helpers
    format = {
      encrypt: ->(token, session_id) { "enc:#{token}:#{session_id}" },
      decrypt: ->(value) {
        _prefix, token, = value.split(":", 3)
        token
      }
    }
    encoded = BetterAuth::Plugins::OAuthProtocol.encode_refresh_token(
      "refresh-secret",
      prefix: {refresh_token: "rt_"},
      format_refresh_token: format,
      session_id: "session-1"
    )
    decoded = BetterAuth::Plugins::OAuthProtocol.decode_refresh_token(
      encoded,
      prefix: {refresh_token: "rt_"},
      format_refresh_token: format
    )

    assert_equal "refresh-secret", decoded
  end
end
