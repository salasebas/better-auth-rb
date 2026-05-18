# frozen_string_literal: true

require "rubygems"

module BetterAuth
  module Telemetry
    module Detectors
      # Framework detector. Returns a small hash describing the Ruby
      # web framework hosting the application (or `nil` when no
      # supported framework gem is loaded).
      #
      # This is the Ruby-specific replacement for upstream's
      # `detect-framework.ts`, which walked the Node `package.json`
      # for known JavaScript frameworks. The Ruby port instead probes
      # `Gem.loaded_specs` for the canonical Ruby web framework gems
      # in declaration order; the first hit wins.
      #
      # ## Probe order (Requirement 11.1)
      #
      # 1. `rails`
      # 2. `sinatra`
      # 3. `hanami`
      # 4. `hanami-router`
      # 5. `roda`
      # 6. `grape`
      # 7. `rack`
      #
      # `rack` is intentionally last so a Rails or Sinatra app does
      # not get reported as a "rack" app just because Rack is a
      # transitive dependency.
      #
      # ## Failure handling
      #
      # The whole call is wrapped in `rescue StandardError; nil` so a
      # surprise from `Gem.loaded_specs` (e.g. a mutated registry, a
      # `respond_to?(:version)` shim that raises) degrades to `nil`
      # rather than escaping out of the init payload composition in
      # {BetterAuth::Telemetry.create}.
      #
      # Node-only frameworks (`next`, `nuxt`, `astro`, `sveltekit`,
      # `solid-start`, `tanstack-start`, `hono`, `express`, `elysia`,
      # `expo`) are intentionally not probed (Requirement 11.4).
      #
      # @example Rails app
      #   BetterAuth::Telemetry::Detectors::Framework.call
      #   # => {name: "rails", version: "7.1.3"}
      #
      # @example No supported framework loaded
      #   BetterAuth::Telemetry::Detectors::Framework.call
      #   # => nil
      module Framework
        # Gems to probe in `Gem.loaded_specs`, in upstream/spec order.
        # First match wins.
        GEMS = %w[rails sinatra hanami hanami-router roda grape rack].freeze

        module_function

        # Resolve the framework signal for the host application by
        # walking {GEMS} in order against `Gem.loaded_specs`.
        #
        # @return [Hash{Symbol => String}, nil] either
        #   `{name: String, version: String}` for the first matching
        #   gem, or `nil` when none of the supported framework gems
        #   are loaded.
        def call
          GEMS.each do |name|
            spec = ::Gem.loaded_specs[name]
            next if spec.nil?

            version = spec.respond_to?(:version) ? spec.version : nil
            return {name: name, version: version&.to_s}
          end
          nil
        rescue
          nil
        end
      end
    end
  end
end
