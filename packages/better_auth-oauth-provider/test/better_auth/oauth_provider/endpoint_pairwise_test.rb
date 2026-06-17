# frozen_string_literal: true

require "jwt"
require_relative "../../test_helper"

class OAuthProviderEndpointPairwiseTest < Minitest::Test
  include OAuthProviderFlowHelpers

  def test_introspection_includes_upstream_claims_for_opaque_tokens
    auth = build_auth(scopes: ["openid", "profile", "offline_access"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid profile offline_access", skip_consent: true)
    tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid profile offline_access")

    active = auth.api.o_auth2_introspect(body: introspect_body(client, tokens[:access_token]))

    assert_equal true, active[:active]
    assert_equal client[:client_id], active[:client_id]
    assert_equal "openid profile offline_access", active[:scope]
    assert_equal "http://localhost:3000", active[:iss]
    assert_kind_of Integer, active[:iat]
    assert_kind_of Integer, active[:exp]
    assert active[:sid]
  end

  def test_introspection_rejects_unauthenticated_client_request
    auth = build_auth(scopes: ["read"])

    error = assert_raises(BetterAuth::APIError) do
      auth.api.o_auth2_introspect(body: {token: "missing"})
    end

    assert_equal 401, error.status_code
    assert_match(/invalid_client/i, error.message)
  end

  def test_introspection_without_hint_detects_opaque_refresh_and_jwt_tokens
    auth = build_auth(scopes: ["openid", "offline_access", "read"], valid_audiences: ["https://api.example"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid offline_access read", skip_consent: true)
    opaque = issue_authorization_code_tokens(auth, cookie, client, scope: "openid offline_access")
    jwt = issue_authorization_code_tokens(auth, cookie, client, scope: "openid offline_access read", resource: "https://api.example")

    access_active = auth.api.o_auth2_introspect(body: introspect_body(client, opaque[:access_token], hint: nil))
    refresh_active = auth.api.o_auth2_introspect(body: introspect_body(client, opaque[:refresh_token], hint: nil))
    jwt_active = auth.api.o_auth2_introspect(body: introspect_body(client, jwt[:access_token], hint: nil))

    assert_equal true, access_active[:active]
    assert_equal "openid offline_access", access_active[:scope]
    assert_equal true, refresh_active[:active]
    assert_equal "openid offline_access", refresh_active[:scope]
    assert_equal true, jwt_active[:active]
    assert_equal "openid offline_access read", jwt_active[:scope]
    assert_equal ["https://api.example", "http://localhost:3000/api/auth/oauth2/userinfo"], jwt_active[:aud]
  end

  def test_introspection_remains_active_after_user_session_is_deleted
    auth = build_auth(scopes: ["openid", "offline_access", "read"], valid_audiences: ["https://api.example"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid offline_access read", skip_consent: true)
    opaque = issue_authorization_code_tokens(auth, cookie, client, scope: "openid offline_access")
    jwt = issue_authorization_code_tokens(auth, cookie, client, scope: "openid offline_access read", resource: "https://api.example")
    user = auth.context.adapter.find_one(model: "user", where: [{field: "email", value: "oauth-provider@example.com"}])

    auth.context.adapter.delete(model: "session", where: [{field: "userId", value: user.fetch("id")}])

    assert_equal true, auth.api.o_auth2_introspect(body: introspect_body(client, opaque[:access_token], hint: nil))[:active]
    assert_equal true, auth.api.o_auth2_introspect(body: introspect_body(client, opaque[:refresh_token], hint: nil))[:active]
    assert_equal true, auth.api.o_auth2_introspect(body: introspect_body(client, jwt[:access_token], hint: nil))[:active]
  end

  def test_revocation_rejects_token_type_hint_mismatches
    auth = build_auth(scopes: ["openid", "offline_access"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid offline_access", skip_consent: true)
    tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid offline_access")

    access_hint = assert_raises(BetterAuth::APIError) do
      auth.api.o_auth2_revoke(body: revoke_body(client, tokens[:refresh_token], hint: "access_token"))
    end
    assert_equal 400, access_hint.status_code

    refresh_hint = assert_raises(BetterAuth::APIError) do
      auth.api.o_auth2_revoke(body: revoke_body(client, tokens[:access_token], hint: "refresh_token"))
    end
    assert_equal 400, refresh_hint.status_code
  end

  def test_revocation_rejects_unauthenticated_client_request
    auth = build_auth(scopes: ["read"])

    error = assert_raises(BetterAuth::APIError) do
      auth.api.o_auth2_revoke(body: {token: "missing"})
    end

    assert_equal 401, error.status_code
    assert_match(/invalid_client/i, error.message)
  end

  def test_revocation_without_hint_revokes_opaque_and_refresh_tokens
    auth = build_auth(scopes: ["openid", "offline_access"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid offline_access", skip_consent: true)
    access_tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid offline_access")
    refresh_tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid offline_access")

    assert_equal({revoked: true}, auth.api.o_auth2_revoke(body: revoke_body(client, access_tokens[:access_token], hint: nil)))
    inactive_access = auth.api.o_auth2_introspect(body: introspect_body(client, access_tokens[:access_token], hint: nil))
    assert_equal false, inactive_access[:active]

    assert_equal({revoked: true}, auth.api.o_auth2_revoke(body: revoke_body(client, refresh_tokens[:refresh_token], hint: nil)))
    inactive_refresh = auth.api.o_auth2_introspect(body: introspect_body(client, refresh_tokens[:refresh_token], hint: nil))
    assert_equal false, inactive_refresh[:active]
  end

  def test_revocation_accepts_jwt_access_tokens_with_and_without_access_hint
    auth = build_auth(scopes: ["openid", "read"], valid_audiences: ["https://api.example"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid read", skip_consent: true)
    hinted = issue_authorization_code_tokens(auth, cookie, client, scope: "openid read", resource: "https://api.example")
    unhinted = issue_authorization_code_tokens(auth, cookie, client, scope: "openid read", resource: "https://api.example")

    assert_equal({revoked: true}, auth.api.o_auth2_revoke(body: revoke_body(client, hinted[:access_token], hint: "access_token")))
    assert_equal({revoked: true}, auth.api.o_auth2_revoke(body: revoke_body(client, unhinted[:access_token], hint: nil)))
  end

  def test_userinfo_supports_jwt_resource_access_token_when_openid_scope_present
    auth = build_auth(scopes: ["openid", "profile"], valid_audiences: ["https://api.example"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid profile", skip_consent: true)
    tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid profile", resource: "https://api.example")

    userinfo = auth.api.o_auth2_user_info(headers: {"authorization" => "Bearer #{tokens[:access_token]}"})

    assert userinfo[:sub]
    assert_equal "OAuth Owner", userinfo[:name]
  end

  def test_logout_invalid_id_token_hint_and_json_success_without_redirect
    auth = build_auth(scopes: ["openid"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid", enable_end_session: true, skip_consent: true)

    invalid = assert_raises(BetterAuth::APIError) do
      auth.api.o_auth2_end_session(query: {id_token_hint: "not-a-jwt"})
    end
    assert_equal 401, invalid.status_code

    tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid")
    assert_equal({status: true}, auth.api.o_auth2_end_session(query: {id_token_hint: tokens[:id_token]}))
  end

  def test_dynamic_registration_cannot_enable_end_session
    auth = build_auth(scopes: ["openid"])
    cookie = sign_up_cookie(auth)

    error = assert_raises(BetterAuth::APIError) do
      register_client(
        auth,
        cookie,
        redirect_uris: ["https://resource.example/callback"],
        post_logout_redirect_uris: ["https://resource.example/logout"],
        scope: "openid",
        enable_end_session: true
      )
    end

    assert_equal 400, error.status_code
    assert_match(/enable_end_session/i, error.message)
  end

  def test_pairwise_registration_requires_secret_and_same_redirect_host
    without_secret = build_auth(scopes: ["openid"])

    no_secret = assert_raises(BetterAuth::APIError) do
      without_secret.api.admin_create_o_auth_client(body: pairwise_client_body("https://app.example.com/cb"))
    end
    assert_equal 400, no_secret.status_code

    with_secret = build_auth(scopes: ["openid"], pairwise_secret: "pairwise-secret-with-enough-entropy-123")
    secret_cookie = sign_up_cookie(with_secret)
    mixed_hosts = pairwise_client_body("https://app.example.com/cb").merge(redirect_uris: ["https://app.example.com/cb", "https://other.example.com/cb"])

    mixed = assert_raises(BetterAuth::APIError) do
      with_secret.api.admin_create_o_auth_client(body: mixed_hosts)
    end
    assert_equal 400, mixed.status_code

    client = with_secret.api.admin_create_o_auth_client(body: pairwise_client_body("https://app.example.com/cb"))
    tokens = issue_authorization_code_tokens(with_secret, secret_cookie, client, scope: "openid", redirect_uri: "https://app.example.com/cb")
    payload = decode_id_token(tokens[:id_token], client)

    refute_equal with_secret.context.adapter.find_one(model: "user", where: [{field: "email", value: "oauth-provider@example.com"}]).fetch("id"), payload.fetch("sub")
  end

  def test_pairwise_subject_is_same_for_clients_on_same_sector_host
    auth = build_auth(scopes: ["openid"], pairwise_secret: "pairwise-secret-with-enough-entropy-123")
    cookie = sign_up_cookie(auth)
    client_a = auth.api.admin_create_o_auth_client(body: pairwise_client_body("https://sector.example.com/a/callback"))
    client_b = auth.api.admin_create_o_auth_client(body: pairwise_client_body("https://sector.example.com/b/callback"))

    tokens_a = issue_authorization_code_tokens(auth, cookie, client_a, scope: "openid", redirect_uri: "https://sector.example.com/a/callback")
    tokens_b = issue_authorization_code_tokens(auth, cookie, client_b, scope: "openid", redirect_uri: "https://sector.example.com/b/callback")
    sub_a = decode_id_token(tokens_a[:id_token], client_a).fetch("sub")
    sub_b = decode_id_token(tokens_b[:id_token], client_b).fetch("sub")

    assert_equal sub_a, sub_b
  end

  def test_pairwise_subject_is_preserved_after_refresh
    auth = build_auth(scopes: ["openid", "offline_access"], pairwise_secret: "pairwise-secret-with-enough-entropy-123")
    cookie = sign_up_cookie(auth)
    client = auth.api.admin_create_o_auth_client(
      body: pairwise_client_body("https://app.example.com/cb").merge(
        grant_types: ["authorization_code", "refresh_token"],
        scope: "openid offline_access"
      )
    )

    tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid offline_access", redirect_uri: "https://app.example.com/cb")
    refreshed = auth.api.o_auth2_token(body: refresh_grant_body(client, tokens[:refresh_token]))
    original_sub = decode_id_token(tokens[:id_token], client).fetch("sub")
    refreshed_sub = decode_id_token(refreshed[:id_token], client).fetch("sub")

    assert_equal original_sub, refreshed_sub
  end

  def test_pairwise_jwt_access_token_keeps_user_id_subject
    auth = build_auth(
      scopes: ["openid", "read"],
      valid_audiences: ["https://api.example"],
      pairwise_secret: "pairwise-secret-with-enough-entropy-123"
    )
    cookie = sign_up_cookie(auth)
    client = auth.api.admin_create_o_auth_client(body: pairwise_client_body("https://app.example.com/cb").merge(scope: "openid read"))

    tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid read", redirect_uri: "https://app.example.com/cb", resource: "https://api.example")
    id_payload = decode_id_token(tokens[:id_token], client)
    access_payload = JWT.decode(tokens[:access_token], nil, false).first
    user = auth.context.adapter.find_one(model: "user", where: [{field: "email", value: "oauth-provider@example.com"}])

    refute_equal user.fetch("id"), id_payload.fetch("sub")
    assert_equal user.fetch("id"), access_payload.fetch("sub")
  end

  def test_pairwise_secret_length_and_metadata_subject_types
    short = assert_raises(BetterAuth::APIError) do
      build_auth(scopes: ["openid"], pairwise_secret: "short")
    end
    assert_match(/pairwise_secret/i, short.message)

    public_only = build_auth(scopes: ["openid"]).api.get_open_id_config
    pairwise = build_auth(scopes: ["openid"], pairwise_secret: "pairwise-secret-with-enough-entropy-123").api.get_open_id_config

    assert_equal ["public"], public_only[:subject_types_supported]
    assert_equal ["public", "pairwise"], pairwise[:subject_types_supported]
  end
end
