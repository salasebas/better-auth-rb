# frozen_string_literal: true

return if defined?(BetterAuth::Plugins::OAUTH_PROVIDER_PLUGIN_IMPLEMENTATION)

module BetterAuth
  module Plugins
    module_function

    def oauth_provider(*args, &block)
      call_external_plugin!(:oauth_provider, *args, implementation_constant: :OAUTH_PROVIDER_PLUGIN_IMPLEMENTATION, gem_name: "better_auth-oauth-provider", entry: "lib/better_auth/oauth_provider.rb", &block)
    end
  end
end
