# frozen_string_literal: true

require_relative "../../test_helper"

class OAuthProviderJwtPluginRequirementTest < Minitest::Test
  include OAuthProviderFlowHelpers

  def test_init_fails_without_jwt_plugin_when_not_disabled
    error = assert_raises(BetterAuth::Error) do
      BetterAuth.auth(
        base_url: "http://localhost:3000",
        secret: SECRET,
        database: :memory,
        email_and_password: {enabled: true},
        plugins: [BetterAuth::Plugins.oauth_provider(scopes: ["openid"])]
      )
    end

    assert_equal "jwt_config", error.message
  end

  def test_disable_jwt_plugin_allows_init_without_jwt
    auth = build_auth(scopes: ["openid"], disable_jwt_plugin: true)
    assert auth.api.get_openid_config[:issuer]
  end
end
