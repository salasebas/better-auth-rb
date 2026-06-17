# frozen_string_literal: true

require_relative "../../test_helper"

class OAuthProviderClientManagementTest < Minitest::Test
  include OAuthProviderFlowHelpers

  def test_cached_trusted_clients_are_immutable_through_crud_endpoints
    auth = build_auth(
      scopes: ["openid"],
      cached_trusted_clients: Set.new(["trusted-client"]),
      generate_client_id: -> { "trusted-client" }
    )
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid")
    assert_equal "trusted-client", client[:client_id]

    update_error = assert_raises(BetterAuth::APIError) do
      auth.api.update_o_auth_client(
        headers: {"cookie" => cookie},
        body: {client_id: client[:client_id], update: {client_name: "Updated"}}
      )
    end
    assert_equal 500, update_error.status_code

    rotate_error = assert_raises(BetterAuth::APIError) do
      auth.api.rotate_o_auth_client_secret(headers: {"cookie" => cookie}, body: {client_id: client[:client_id]})
    end
    assert_equal 500, rotate_error.status_code

    delete_error = assert_raises(BetterAuth::APIError) do
      auth.api.delete_o_auth_client(headers: {"cookie" => cookie}, body: {client_id: client[:client_id]})
    end
    assert_equal 500, delete_error.status_code
  end

  def test_dynamic_registration_can_set_client_secret_expiration
    auth = build_auth(
      scopes: ["openid"],
      allow_dynamic_client_registration: true,
      client_registration_client_secret_expiration: "30 days"
    )
    cookie = sign_up_cookie(auth)

    client = register_client(auth, cookie, scope: "openid")

    assert client[:client_secret_expires_at].to_i.positive?
  end

  private

  def create_client(auth, cookie, **options)
    auth.api.create_o_auth_client(headers: {"cookie" => cookie}, body: {
      client_name: options[:client_name] || "Test Client",
      redirect_uris: ["https://client.example.com/callback"],
      token_endpoint_auth_method: options[:token_endpoint_auth_method] || "client_secret_post",
      grant_types: ["authorization_code"],
      response_types: ["code"],
      scope: options[:scope] || "openid"
    })
  end
end
