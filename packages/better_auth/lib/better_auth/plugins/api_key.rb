# frozen_string_literal: true

return if defined?(BetterAuth::Plugins::API_KEY_PLUGIN_IMPLEMENTATION)

module BetterAuth
  module Plugins
    module_function

    def api_key(*args, &block)
      call_external_plugin!(:api_key, *args, implementation_constant: :API_KEY_PLUGIN_IMPLEMENTATION, gem_name: "better_auth-api-key", entry: "lib/better_auth/api_key.rb", &block)
    end
  end
end
