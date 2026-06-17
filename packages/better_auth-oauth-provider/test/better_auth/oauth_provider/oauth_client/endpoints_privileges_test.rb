# frozen_string_literal: true

require_relative "../../../test_helper"

class OAuthProviderOauthClientEndpointsPrivilegesTest < Minitest::Test
  include OAuthProviderFlowHelpers

  def test_client_privileges_can_block_list_endpoint
    auth = build_auth(scopes: ["openid", "profile", "email", "offline_access", "read", "write"], client_privileges: ->(info) { info[:action] != "list" })
    cookie = sign_up_cookie(auth)
    create_client(auth, cookie)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.get_oauth_clients(headers: {"cookie" => cookie})
    end

    assert_equal 401, error.status_code
  end
end
