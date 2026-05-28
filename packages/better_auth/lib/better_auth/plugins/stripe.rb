# frozen_string_literal: true

return if defined?(BetterAuth::Plugins::STRIPE_PLUGIN_IMPLEMENTATION)

module BetterAuth
  module Plugins
    module_function

    def stripe(*args, &block)
      call_external_plugin!(:stripe, *args, implementation_constant: :STRIPE_PLUGIN_IMPLEMENTATION, gem_name: "better_auth-stripe", entry: "lib/better_auth/stripe.rb", &block)
    end
  end
end
