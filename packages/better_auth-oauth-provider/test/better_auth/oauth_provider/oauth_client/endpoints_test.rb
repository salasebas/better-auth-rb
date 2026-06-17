# frozen_string_literal: true

require_relative "../../../test_helper"

class OAuthProviderOauthClientEndpointsTest < Minitest::Test
  include OAuthProviderFlowHelpers

  def test_client_management_create_read_list_update_rotate_delete
    auth = build_auth(scopes: ["openid", "profile", "email", "offline_access", "read", "write"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, client_name: "Original Client")

    fetched = auth.api.get_oauth_client(headers: {"cookie" => cookie}, query: {client_id: client[:client_id]})
    listed = auth.api.get_oauth_clients(headers: {"cookie" => cookie})
    updated = auth.api.update_oauth_client(headers: {"cookie" => cookie}, body: {client_id: client[:client_id], update: {client_name: "Updated Client"}})
    rotated = auth.api.rotate_oauth_client_secret(headers: {"cookie" => cookie}, body: {client_id: client[:client_id]})
    deleted = auth.api.delete_oauth_client(headers: {"cookie" => cookie}, body: {client_id: client[:client_id]})

    assert_equal "Original Client", fetched[:client_name]
    assert_includes listed.map { |item| item[:client_id] }, client[:client_id]
    assert_equal "Updated Client", updated[:client_name]
    refute_equal client[:client_secret], rotated[:client_secret]
    assert_equal({deleted: true}, deleted)
  end

  def test_public_client_prelogin_requires_feature_flag_and_signed_oauth_query
    auth = build_auth(scopes: ["openid"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid", skip_consent: true)
    signed_query = signed_oauth_query(auth, client)

    disabled = assert_raises(BetterAuth::APIError) do
      auth.api.get_oauth_client_public_prelogin(body: {client_id: client[:client_id], oauth_query: signed_query})
    end
    assert_equal 400, disabled.status_code

    enabled = build_auth(scopes: ["openid"], allow_public_client_prelogin: true)
    enabled_cookie = sign_up_cookie(enabled, email: "prelogin@example.com")
    enabled_client = create_client(enabled, enabled_cookie, scope: "openid", skip_consent: true)

    missing = assert_raises(BetterAuth::APIError) do
      enabled.api.get_oauth_client_public_prelogin(body: {client_id: enabled_client[:client_id]})
    end
    assert_equal 401, missing.status_code

    invalid = assert_raises(BetterAuth::APIError) do
      enabled.api.get_oauth_client_public_prelogin(body: {client_id: enabled_client[:client_id], oauth_query: "client_id=#{enabled_client[:client_id]}&sig=bad"})
    end
    assert_equal 401, invalid.status_code

    public_client = enabled.api.get_oauth_client_public_prelogin(
      body: {
        client_id: enabled_client[:client_id],
        oauth_query: signed_oauth_query(enabled, enabled_client)
      }
    )
    assert_equal enabled_client[:client_id], public_client[:client_id]
    assert_nil public_client[:client_secret]
  end

  def test_update_client_rejects_unsafe_redirect_uri
    auth = build_auth(scopes: ["openid"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.update_oauth_client(
        headers: {"cookie" => cookie},
        body: {
          client_id: client[:client_id],
          update: {redirect_uris: ["javascript:alert(1)"]}
        }
      )
    end

    assert_equal 400, error.status_code
    assert_match(/redirect_uris/i, error.message)
  end

  def test_admin_update_client_validates_merged_client_metadata
    auth = build_auth(scopes: ["openid"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.admin_update_oauth_client(
        body: {
          client_id: client[:client_id],
          update: {
            token_endpoint_auth_method: "none",
            grant_types: ["client_credentials"],
            response_types: []
          }
        }
      )
    end

    assert_equal 400, error.status_code
    assert_match(/public clients cannot use client_credentials/i, error.message)
  end

  private

  def signed_oauth_query(auth, client)
    ctx = Struct.new(:context).new(context: auth.context)
    BetterAuth::Plugins.oauth_signed_query(
      ctx,
      {
        client_id: client[:client_id],
        redirect_uri: "https://resource.example/callback",
        response_type: "code",
        scope: "openid"
      }
    )
  end
end
