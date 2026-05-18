# frozen_string_literal: true

require_relative "../../test_helper"
require "better_auth/telemetry/detectors/environment"
require_relative "../support/env_helpers"

# Property-based test for the environment classifier.
#
# This property sweeps the Cartesian product of the inputs the
# classifier inspects (`RACK_ENV`/`RAILS_ENV`/`APP_ENV` and the
# CI-marker variables) and asserts that the value returned by
# `BetterAuth::Telemetry::Detectors::Environment.call` is always one
# of `{"production", "ci", "test", "development"}` and respects the
# precedence rule `production > ci > test > development` documented
# in Requirement 8.
#
# `prop_check` is not bundled in this package, so the property runs as
# a deterministic Minitest case backed by a seeded `Random`. The
# structure intentionally mirrors the other property tests in this
# directory (e.g. `env_property_test.rb`) so swapping in `prop_check`
# later (gated by the conditional require in `test/test_helper.rb`)
# is mechanical.
module BetterAuth
  module Telemetry
    class EnvironmentClassifierPropertyTest < Minitest::Test
      include BetterAuth::Telemetry::Test::EnvHelpers

      Environment = BetterAuth::Telemetry::Detectors::Environment

      # Number of randomised iterations. Bumped above the design floor
      # (100) so the alphabet of CI markers gets a fair sweep while
      # keeping the test fast.
      ITERATIONS = 200

      # Fixed seed so a counter-example can be reproduced verbatim by
      # rerunning the file. If you change the seed, write the new seed
      # into the test (do not rely on the global default).
      SEED = 0xE19_1A55

      # Allowed return values per Requirement 8 / Property 7.
      ALLOWED_RESULTS = %w[production ci test development].freeze

      # Generators for the precedence inputs. Mirrors the design
      # (`design.md` § Property 7): each TEST_VARS entry is one of
      # `{"production", "test", "", absent}` and each CI marker is one
      # of `{set, unset, "false"}`.
      TEST_VAR_VALUES = [nil, "", "production", "test"].freeze
      CI_VAR_VALUES = [nil, "1", "false"].freeze

      # Every env variable the classifier inspects. Each iteration
      # writes an explicit value (possibly `nil`) for every one of
      # these so a CI build (which exports `CI` and friends) cannot
      # leak into the assertion.
      ALL_VARS = (Environment::TEST_VARS + Environment::CI_VARS).freeze

      # ---------------------------------------------------------------------
      # Property 7: Environment classifier precedence.
      #
      # *For any* assignment of values to the relevant environment
      # variables — `RACK_ENV`, `RAILS_ENV`, `APP_ENV` (each in
      # `{"production", "test", "", absent}`) and the CI-marker
      # variables (each in `{set, unset, "false"}`) — the value
      # returned by `BetterAuth::Telemetry::Detectors::Environment.call`
      # SHALL be one of the strings
      # `{"production", "ci", "test", "development"}` AND SHALL respect
      # the precedence rule `production > ci > test > development`.
      #
      # Validates: Requirements 8.1, 8.2, 8.3, 8.4, 20.7
      # ---------------------------------------------------------------------
      def test_property_7_environment_classifier_precedence
        rng = Random.new(SEED)

        # Deterministic boundary samples first. These exercise every
        # documented branch of the classifier (and the four-way
        # precedence ladder) before random generation starts, so a
        # regression on a documented value fails loudly.
        deterministic_samples.each do |sample|
          assert_classifier_matches_spec(sample)
        end

        remaining = ITERATIONS - deterministic_samples.length
        remaining = 0 if remaining.negative?
        remaining.times do
          assert_classifier_matches_spec(random_sample(rng))
        end
      end

      private

      # Build an env-state hash where every TEST/CI variable has an
      # explicit value (possibly `nil` to delete). The base hash sets
      # every var to `nil`; `extra` overrides a subset.
      def env_state(extra = {})
        ALL_VARS.each_with_object({}) { |key, acc| acc[key] = nil }
          .merge(extra.transform_keys(&:to_s))
      end

      # Documented branch coverage. Each entry covers one row of the
      # precedence ladder using a representative TEST_VARS member and a
      # representative CI marker.
      def deterministic_samples
        @deterministic_samples ||= [
          # development: nothing set
          env_state,
          # test: only RACK_ENV=test
          env_state("RACK_ENV" => "test"),
          # test: only RAILS_ENV=test
          env_state("RAILS_ENV" => "test"),
          # test: only APP_ENV=test
          env_state("APP_ENV" => "test"),
          # ci wins over test (CI=1 + RAILS_ENV=test)
          env_state("RAILS_ENV" => "test", "CI" => "1"),
          # production wins over ci + test
          env_state("RAILS_ENV" => "production", "CI" => "1", "RACK_ENV" => "test"),
          # production via APP_ENV alone
          env_state("APP_ENV" => "production"),
          # CI=false is treated as unset
          env_state("CI" => "false"),
          # CI="" is treated as unset
          env_state("CI" => ""),
          # CI=false does not outrank a test marker
          env_state("CI" => "false", "RAILS_ENV" => "test"),
          # arbitrary non-"false" CI marker flips to ci
          env_state("BUILD_ID" => "1234"),
          # every CI marker individually flips to ci
          *Environment::CI_VARS.map { |marker| env_state(marker => "1") }
        ].freeze
      end

      # Generate a random env-state hash. Each TEST_VARS entry draws
      # uniformly from `TEST_VAR_VALUES`; each CI marker draws
      # uniformly from `CI_VAR_VALUES`. Keys absent from the result
      # default to `nil` via `env_state`.
      def random_sample(rng)
        overrides = {}
        Environment::TEST_VARS.each do |key|
          overrides[key] = TEST_VAR_VALUES.sample(random: rng)
        end
        Environment::CI_VARS.each do |key|
          overrides[key] = CI_VAR_VALUES.sample(random: rng)
        end
        env_state(overrides)
      end

      # Apply `state` to the live `ENV`, call the classifier, and
      # assert the result is allowed and matches the precedence rule
      # re-derived directly from the spec prose.
      def assert_classifier_matches_spec(state)
        expected = expected_classification(state)

        with_env(state) do
          actual = Environment.call

          assert_includes(
            ALLOWED_RESULTS,
            actual,
            "Environment.call returned #{actual.inspect}, " \
            "which is not in #{ALLOWED_RESULTS.inspect} " \
            "for env state #{state.inspect}"
          )

          assert_equal(
            expected,
            actual,
            "Environment.call violated the precedence rule for env " \
            "state #{state.inspect}"
          )
        end
      end

      # Re-derive the spec's classification for `state` without going
      # through the implementation: production wins over ci wins over
      # test wins over development.
      def expected_classification(state)
        return "production" if Environment::TEST_VARS.any? { |k| state[k] == "production" }
        return "ci" if Environment::CI_VARS.any? { |k| ci_marker_active?(state[k]) }
        return "test" if Environment::TEST_VARS.any? { |k| state[k] == "test" }

        "development"
      end

      # A CI marker counts as active when it is present, non-empty,
      # and not the case-insensitive string `"false"`.
      def ci_marker_active?(value)
        return false if value.nil?
        return false if value.empty?
        return false if value.casecmp("false").zero?

        true
      end
    end
  end
end
