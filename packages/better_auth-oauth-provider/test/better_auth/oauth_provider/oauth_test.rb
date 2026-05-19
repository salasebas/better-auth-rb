# frozen_string_literal: true

require_relative "../../test_helper"

class OAuthProviderOauthTest < Minitest::Test
  def test_plugin_entrypoint_uses_oauth_provider_models_not_oidc_provider_models
    plugin = BetterAuth::Plugins.oauth_provider(scopes: ["openid"])
    schema_models = plugin.schema.values.filter_map { |table| table[:model_name] || table[:modelName] }

    assert_equal "oauth-provider", plugin.id
    assert_includes schema_models, "oauth_clients"
    assert_includes schema_models, "oauth_access_tokens"
    assert_includes schema_models, "oauth_consents"
    assert_includes plugin.schema.keys.map(&:to_s), "oauth_refresh_token"
    refute_includes schema_models, "oidcProvider"
    refute_includes schema_models, "oauthApplication"
  end
end
