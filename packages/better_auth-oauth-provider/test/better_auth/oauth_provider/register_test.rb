# frozen_string_literal: true

require_relative "../../test_helper"

class OAuthProviderRegisterTest < Minitest::Test
  include OAuthProviderFlowHelpers

  def test_dynamic_registration_defaults_to_pkce_and_strips_unknown_metadata
    auth = build_auth(scopes: ["openid", "profile"])
    cookie = sign_up_cookie(auth)

    client = register_client(
      auth,
      cookie,
      scope: "openid",
      metadata: {trusted: true, software_id: "software-1"}
    )

    assert_equal true, client[:require_pkce]
    assert_equal "software-1", client[:metadata]["software_id"]
    refute client[:metadata].key?("trusted")
  end

  def test_dynamic_registration_rejects_scalar_metadata
    auth = build_auth(scopes: ["openid"])
    cookie = sign_up_cookie(auth)

    error = assert_raises(BetterAuth::APIError) do
      register_client(auth, cookie, scope: "openid", metadata: "not-an-object")
    end

    assert_equal 400, error.status_code
    assert_match(/metadata/i, error.message)
  end

  def test_unauthenticated_registration_when_enabled
    auth = build_auth(scopes: ["openid"], allow_unauthenticated_client_registration: true)

    client = register_client(auth, nil, scope: "openid")

    assert client[:client_id]
    assert_equal "none", client[:token_endpoint_auth_method]
  end

  def test_registration_rejects_scopes_outside_allowed_list
    auth = build_auth(
      scopes: ["openid", "profile"],
      client_registration_allowed_scopes: ["openid"]
    )
    cookie = sign_up_cookie(auth)

    error = assert_raises(BetterAuth::APIError) do
      register_client(auth, cookie, scope: "openid profile")
    end

    assert_equal 400, error.status_code
    assert_match(/invalid_scope/, error.message)
  end

  def test_registration_rejects_missing_redirect_uris
    auth = build_auth(scopes: ["openid"])
    cookie = sign_up_cookie(auth)

    error = assert_raises(BetterAuth::APIError) do
      register_client(auth, cookie, redirect_uris: [], scope: "openid")
    end

    assert_equal 400, error.status_code
    assert_match(/redirect_uris/, error.message)
  end

  def test_public_native_client_defaults_to_none_auth_method
    auth = build_auth(scopes: ["openid"], allow_unauthenticated_client_registration: true)

    client = register_client(
      auth,
      nil,
      redirect_uris: ["com.example.app:/callback"],
      type: "native",
      token_endpoint_auth_method: "none",
      grant_types: ["authorization_code"],
      response_types: ["code"],
      scope: "openid"
    )

    assert_equal "none", client[:token_endpoint_auth_method]
  end

  def test_pairwise_registration_requires_server_pairwise_secret
    auth = build_auth(scopes: ["openid"])
    cookie = sign_up_cookie(auth)

    error = assert_raises(BetterAuth::APIError) do
      register_client(
        auth,
        cookie,
        subject_type: "pairwise",
        scope: "openid"
      )
    end

    assert_equal 400, error.status_code
    assert_match(/pairwise_secret/, error.message)
  end

  def test_registration_includes_client_secret_expiration_when_configured
    auth = build_auth(
      scopes: ["openid"],
      client_registration_client_secret_expiration: 3600
    )
    cookie = sign_up_cookie(auth)

    client = register_client(auth, cookie, scope: "openid")

    assert client[:client_secret_expires_at].to_i.positive?
  end
end
