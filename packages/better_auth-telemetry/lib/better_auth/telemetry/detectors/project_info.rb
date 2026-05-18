# frozen_string_literal: true

module BetterAuth
  module Telemetry
    module Detectors
      # ProjectInfo detector. Returns a small hash describing the
      # project's "package manager" — for the Ruby port, this is
      # always Bundler (or `nil` when Bundler is not available).
      #
      # This is the Ruby-specific replacement for upstream's
      # `detect-project-info.ts`, which parsed the
      # `npm_config_user_agent` env var to determine the npm/yarn/pnpm
      # toolchain. There is no equivalent Ruby env var; Bundler is the
      # closest semantic match.
      #
      # ## Detection rule (Requirements 12.1 / 12.2)
      #
      # 1. If `Bundler` is `defined?` AND `Bundler.default_gemfile`
      #    succeeds (the Gemfile is locatable), return
      #    `{name: "bundler", version: ::Bundler::VERSION}`.
      # 2. Otherwise return `nil`.
      #
      # ## Failure handling
      #
      # The whole call is wrapped in `rescue StandardError; nil` so any
      # surprise from probing Bundler (e.g. a stubbed/partially-loaded
      # Bundler module) degrades to `nil` rather than escaping out of
      # the init payload composition in {BetterAuth::Telemetry.create}.
      #
      # No `npm_config_user_agent` or other Node package-manager env
      # var is read (Requirement 12.3); this Ruby-specific deviation
      # is intentional.
      #
      # @example Inside a Bundler-managed app
      #   BetterAuth::Telemetry::Detectors::ProjectInfo.call
      #   # => {name: "bundler", version: "2.5.3"}
      #
      # @example Bundler not loaded
      #   BetterAuth::Telemetry::Detectors::ProjectInfo.call
      #   # => nil
      module ProjectInfo
        module_function

        # Resolve the project-info signal for the host application.
        #
        # @return [Hash{Symbol => String}, nil] either
        #   `{name: "bundler", version: <Bundler::VERSION>}` when
        #   Bundler is loaded and a Gemfile is locatable, otherwise
        #   `nil`.
        def call
          return nil unless bundler_loaded?
          return nil unless default_gemfile_locatable?

          {name: "bundler", version: ::Bundler::VERSION}
        rescue
          nil
        end

        # Whether the `Bundler` constant is defined in the current
        # process. Extracted as a stub seam so tests can simulate the
        # Bundler-absent case without actually unloading Bundler.
        #
        # @return [Boolean]
        def bundler_loaded?
          defined?(::Bundler) ? true : false
        end

        # Whether `Bundler.default_gemfile` resolves successfully.
        # Bundler raises `Bundler::GemfileNotFound` (a `StandardError`
        # subclass) when no Gemfile is locatable, so we treat any
        # raise as "not locatable" rather than letting it escape.
        #
        # @return [Boolean]
        def default_gemfile_locatable?
          return false unless ::Bundler.respond_to?(:default_gemfile)

          !::Bundler.default_gemfile.nil?
        rescue
          false
        end
      end
    end
  end
end
