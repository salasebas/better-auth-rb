# frozen_string_literal: true

return if defined?(BetterAuth::Plugins::SSO_PLUGIN_IMPLEMENTATION)

module BetterAuth
  module Plugins
    module_function

    def sso(*args)
      loader = BetterAuth::Plugins.method(:sso)
      spec = Gem.loaded_specs["better_auth-sso"] || Gem::Specification.find_by_name("better_auth-sso")
      core_path = File.join(spec.full_gem_path, "lib/better_auth/sso/plugin/core.rb")
      load core_path unless $LOADED_FEATURES.include?(core_path)

      resolved = BetterAuth::Plugins.method(:sso)
      if resolved == loader
        raise LoadError,
          "BetterAuth::Plugins.sso requires the better_auth-sso gem. Add `gem \"better_auth-sso\"` and `require \"better_auth/sso\"`."
      end

      resolved.call(*args)
    rescue Gem::MissingSpecError
      raise LoadError,
        "BetterAuth::Plugins.sso requires the better_auth-sso gem. Add `gem \"better_auth-sso\"` and `require \"better_auth/sso\"`."
    end
  end
end
