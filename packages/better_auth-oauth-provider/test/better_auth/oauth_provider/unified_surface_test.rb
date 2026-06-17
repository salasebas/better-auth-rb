# frozen_string_literal: true

require_relative "../../test_helper"

class OAuthProviderUnifiedSurfaceTest < Minitest::Test
  def test_oauth_provider_is_the_canonical_provider_plugin
    require "better_auth/oauth_provider"

    plugin = BetterAuth::Plugins.oauth_provider(scopes: ["openid"])

    assert_equal "oauth-provider", plugin.id
    refute BetterAuth::Plugins.respond_to?(:oidc_provider)
    refute BetterAuth::Plugins.respond_to?(:mcp)
  end

  def test_removed_core_provider_factories_raise_migration_errors
    require "better_auth"

    oidc_error = assert_raises(ArgumentError) { BetterAuth::Plugins.oidc_provider }
    assert_match(/oauth_provider/i, oidc_error.message)

    mcp_error = assert_raises(ArgumentError) { BetterAuth::Plugins.mcp }
    assert_match(/oauth_provider/i, mcp_error.message)
  end
end
