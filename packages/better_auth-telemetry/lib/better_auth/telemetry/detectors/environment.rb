# frozen_string_literal: true

module BetterAuth
  module Telemetry
    module Detectors
      # Environment detector. Classifies the current process as
      # `"production"`, `"ci"`, `"test"`, or `"development"`, mirroring
      # the upstream `detect-runtime.ts:detectEnvironment` short-circuit
      # chain.
      #
      # Precedence (top wins):
      #
      #   1. `"production"` — when any of `RACK_ENV`, `RAILS_ENV`,
      #      `APP_ENV` equals the literal string `"production"`.
      #   2. `"ci"` — when any of the documented CI marker variables
      #      ({CI_VARS}) is set to a non-empty value that is not the
      #      case-insensitive string `"false"`.
      #   3. `"test"` — when any of `RACK_ENV`, `RAILS_ENV`, `APP_ENV`
      #      equals the literal string `"test"`.
      #   4. `"development"` — fallback when no rule above matches.
      #
      # The CI marker check intentionally skips the literal string
      # `"false"` (case-insensitive) so a host that exports
      # `CI=false` (a common pattern in non-CI shells where CI tooling
      # has been opted out) is not misclassified. Empty values are also
      # treated as unset.
      #
      # @example
      #   BetterAuth::Telemetry::Detectors::Environment.call
      #   # => "development"
      module Environment
        # CI marker variables, in the upstream-defined order. Any
        # non-empty / non-`"false"` value flips the classifier to
        # `"ci"`.
        CI_VARS = %w[
          CI
          BUILD_ID
          BUILD_NUMBER
          CI_APP_ID
          CI_BUILD_ID
          CI_BUILD_NUMBER
          CI_NAME
          CONTINUOUS_INTEGRATION
          RUN_ID
        ].freeze

        # Test/production env variable names that get inspected for the
        # literal `"production"` and `"test"` strings.
        TEST_VARS = %w[RACK_ENV RAILS_ENV APP_ENV].freeze

        module_function

        # @return [String] one of `"production"`, `"ci"`, `"test"`, or
        #   `"development"`.
        def call
          return "production" if any_env_eq?(TEST_VARS, "production")
          return "ci" if ci?
          return "test" if any_env_eq?(TEST_VARS, "test")

          "development"
        end

        # @return [Boolean] true when at least one CI marker variable
        #   has a non-empty value that is not (case-insensitive)
        #   `"false"`.
        def ci?
          CI_VARS.any? do |key|
            value = ENV[key]
            next false if value.nil? || value.empty?
            next false if value.casecmp("false").zero?

            true
          end
        end

        # @param keys [Array<String>] env var names to inspect.
        # @param value [String] expected exact value.
        # @return [Boolean] true when at least one of the named vars
        #   equals `value`.
        def any_env_eq?(keys, value)
          keys.any? { |k| ENV[k] == value }
        end
      end
    end
  end
end
