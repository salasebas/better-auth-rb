# frozen_string_literal: true

return if defined?(BetterAuth::Plugins::SCIM_PLUGIN_IMPLEMENTATION)

module BetterAuth
  module Plugins
    module_function

    def scim(*args, &block)
      call_external_plugin!(:scim, *args, implementation_constant: :SCIM_PLUGIN_IMPLEMENTATION, gem_name: "better_auth-scim", entry: "lib/better_auth/scim.rb", &block)
    end
  end
end
