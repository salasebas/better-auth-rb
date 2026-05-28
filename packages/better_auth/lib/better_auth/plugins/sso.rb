# frozen_string_literal: true

return if defined?(BetterAuth::Plugins::SSO_PLUGIN_IMPLEMENTATION)

module BetterAuth
  module Plugins
    module_function

    def sso(*args, &block)
      call_external_plugin!(:sso, *args, implementation_constant: :SSO_PLUGIN_IMPLEMENTATION, gem_name: "better_auth-sso", entry: "lib/better_auth/sso.rb", &block)
    end
  end
end
