# frozen_string_literal: true

return if defined?(BetterAuth::Plugins::PASSKEY_PLUGIN_IMPLEMENTATION)

module BetterAuth
  module Plugins
    module_function

    def passkey(*args, &block)
      call_external_plugin!(:passkey, *args, implementation_constant: :PASSKEY_PLUGIN_IMPLEMENTATION, gem_name: "better_auth-passkey", entry: "lib/better_auth/passkey.rb", &block)
    end
  end
end
