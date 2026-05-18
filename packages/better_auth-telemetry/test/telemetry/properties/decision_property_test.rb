# frozen_string_literal: true

require_relative "../../test_helper"
require "better_auth/telemetry"
require_relative "../support/env_helpers"
require_relative "../support/recording_track"

# Property-based tests for the opt-in / test-skip / option-overrides-env
# decision table implemented by `BetterAuth::Telemetry.create` (see
# `lib/better_auth/telemetry/create.rb`, `compute_enabled`).
#
# These properties drive the same code path exercised by
# `test/telemetry/create_decision_test.rb`, but instead of pinning each
# of the 24 combinations once they sweep a generated input space
# (deterministic across a fixed `Random` seed) so the table is checked
# exhaustively and then peppered with extra randomized iterations to
# satisfy Requirement 20.8 / the design's ≥100-iteration floor.
#
# `prop_check` is not currently bundled in this package, so the
# properties run as deterministic Minitest cases backed by a seeded
# generator. The structure is intentionally close to a `prop_check`
# property so that swapping in `prop_check` later (gated by the
# conditional require in `test/test_helper.rb`) is mechanical.
#
# Per the task brief, every iteration:
#
#   - generates a random tuple
#     `(options_enabled, env_truthy, in_test_env, skip_test_check)`;
#   - sets `BETTER_AUTH_TELEMETRY` env to a truthy/falsy value matching
#     `env_truthy` (and clears the `OPEN_AUTH_*` alias);
#   - sets `RACK_ENV=test` (with `RAILS_ENV`/`APP_ENV` cleared) when
#     `in_test_env` is true, otherwise clears all three;
#   - builds options with `telemetry: {enabled: options_enabled}` (or
#     omits the key entirely when `options_enabled` is `nil`);
#   - builds context with `skip_test_check: skip_test_check` plus a
#     `RecordingTrack` as `custom_track` so the no-delivery short-circuit
#     never interferes and no HTTP is performed;
#   - calls `BetterAuth::Telemetry.create(options, context)`;
#   - computes the expected `enabled` from Property 3's formula directly
#     from the input tuple (re-derived from the spec, *not* read back
#     from the implementation, so the property is meaningful);
#   - asserts the result is a {Publisher} with `enabled? == true` when
#     expected, otherwise a {NoopPublisher} with `enabled? == false`;
#   - resets `BetterAuth::Telemetry.reset_project_id!` between iterations
#     to avoid memo bleed across cases (the project_id memo can otherwise
#     pin one tuple's resolution onto subsequent tuples).
module BetterAuth
  module Telemetry
    class DecisionPropertyTest < Minitest::Test
      include BetterAuth::Telemetry::Test::EnvHelpers

      Telemetry = BetterAuth::Telemetry
      NoopPublisher = BetterAuth::Telemetry::NoopPublisher
      Publisher = BetterAuth::Telemetry::Publisher
      RecordingTrack = BetterAuth::Telemetry::Test::RecordingTrack

      # Number of additional random iterations layered on top of the
      # exhaustive 24-cell sweep. The design floor is 100; combined with
      # the 24 deterministic cells this yields >=124 total iterations per
      # run.
      RANDOM_ITERATIONS = 100

      # Fixed seed so a counter-example can be reproduced verbatim by
      # rerunning the file. If you change the seed, write the new seed
      # into the test (do not rely on the global default).
      SEED = 0xDEC1_510E

      OPTIONS_ENABLED_DOMAIN = [nil, true, false].freeze
      BOOL_DOMAIN = [true, false].freeze

      # Truthy/falsy literals for `BETTER_AUTH_TELEMETRY`. Drawn from
      # both ends of the {Env.truthy?} classification so the random
      # sweep does not narrow to a single representative value.
      TRUTHY_ENV_LITERALS = %w[1 true TRUE yes on enabled 2].freeze
      FALSY_ENV_LITERALS = ["", "0", "false", "FALSE", "False"].freeze

      # ---------------------------------------------------------------------
      # Property 3: Opt-in / test-skip / option-overrides-env decision table.
      #
      # For every tuple `(options_enabled, env_truthy, in_test_env,
      # skip_test_check)` with:
      #
      #   - options_enabled ∈ {nil, true, false}
      #   - env_truthy      ∈ {true, false}
      #   - in_test_env     ∈ {true, false}
      #   - skip_test_check ∈ {true, false}
      #
      # the `enabled` state computed by `BetterAuth::Telemetry.create` SHALL equal:
      #
      #   opt_in       = options_enabled == true || (options_enabled.nil? && env_truthy)
      #   overridden   = options_enabled == false
      #   in_test_gate = in_test_env && !skip_test_check
      #   enabled      = opt_in && !overridden && !in_test_gate
      #
      # Validates: Requirements 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7
      # ---------------------------------------------------------------------
      def test_property_3_decision_table
        rng = Random.new(SEED)

        # 1. Exhaustive 24-cell deterministic sweep. Every combination
        #    of the four input axes is checked once with random
        #    truthy/falsy env-literal choices so we still get a small
        #    amount of variation even on the deterministic pass.
        OPTIONS_ENABLED_DOMAIN.each do |options_enabled|
          BOOL_DOMAIN.each do |env_truthy|
            BOOL_DOMAIN.each do |in_test_env|
              BOOL_DOMAIN.each do |skip_test_check|
                assert_decision_holds(
                  options_enabled: options_enabled,
                  env_truthy: env_truthy,
                  in_test_env: in_test_env,
                  skip_test_check: skip_test_check,
                  rng: rng
                )
              end
            end
          end
        end

        # 2. Randomized iterations on top of the deterministic sweep.
        #    The same axes are sampled uniformly so the property gets
        #    re-checked across the whole space rather than only the
        #    deterministic corners.
        RANDOM_ITERATIONS.times do
          assert_decision_holds(
            options_enabled: OPTIONS_ENABLED_DOMAIN.sample(random: rng),
            env_truthy: BOOL_DOMAIN.sample(random: rng),
            in_test_env: BOOL_DOMAIN.sample(random: rng),
            skip_test_check: BOOL_DOMAIN.sample(random: rng),
            rng: rng
          )
        end
      end

      private

      # Drive a single iteration of the property: set env, build
      # options/context, call `Telemetry.create`, and assert the
      # publisher matches the decision-table expectation.
      def assert_decision_holds(options_enabled:, env_truthy:, in_test_env:, skip_test_check:, rng:)
        # The project_id memo is process-global; clear it between
        # iterations so a previous tuple's anonymous id resolution does
        # not pin onto this iteration.
        Telemetry.reset_project_id!

        env_overrides = build_env_overrides(env_truthy: env_truthy, in_test_env: in_test_env, rng: rng)
        options = build_options(options_enabled)
        track = RecordingTrack.new
        context = {custom_track: track, skip_test_check: skip_test_check}

        with_env(env_overrides) do
          publisher = Telemetry.create(options, context)
          expected = expected_enabled?(
            options_enabled: options_enabled,
            env_truthy: env_truthy,
            in_test_env: in_test_env,
            skip_test_check: skip_test_check
          )

          label = format_label(
            options_enabled: options_enabled,
            env_truthy: env_truthy,
            in_test_env: in_test_env,
            skip_test_check: skip_test_check,
            env_overrides: env_overrides
          )

          if expected
            assert_kind_of(
              Publisher,
              publisher,
              "expected Publisher for #{label}"
            )
            assert_predicate(
              publisher,
              :enabled?,
              "expected publisher.enabled? to be true for #{label}"
            )
          else
            assert_kind_of(
              NoopPublisher,
              publisher,
              "expected NoopPublisher for #{label}"
            )
            refute_predicate(
              publisher,
              :enabled?,
              "expected publisher.enabled? to be false for #{label}"
            )
          end
        end
      ensure
        # Leave the cache clean for any later test that depends on a
        # cold project_id memo.
        Telemetry.reset_project_id!
      end

      # Re-derive the expected outcome straight from Property 3 so the
      # property does not just round-trip through the implementation.
      def expected_enabled?(options_enabled:, env_truthy:, in_test_env:, skip_test_check:)
        opt_in = options_enabled == true || (options_enabled.nil? && env_truthy)
        overridden = options_enabled == false
        in_test_gate = in_test_env && !skip_test_check
        opt_in && !overridden && !in_test_gate
      end

      # Build the env override hash. We always pin the OPEN_AUTH_* alias
      # to `nil` and the test-env vars we don't want set to `nil`, so the
      # outer process environment can never leak in and skew the
      # iteration's truthy/in_test signal.
      def build_env_overrides(env_truthy:, in_test_env:, rng:)
        better_auth_telemetry =
          if env_truthy
            TRUTHY_ENV_LITERALS.sample(random: rng)
          else
            # Two of the three slots map to "absent"; one to a falsy
            # literal. The classifier must treat all three identically.
            case rng.rand(3)
            when 0 then nil
            when 1 then ""
            else FALSY_ENV_LITERALS.sample(random: rng)
            end
          end

        {
          # Opt-in axis.
          "BETTER_AUTH_TELEMETRY" => better_auth_telemetry,
          "OPEN_AUTH_TELEMETRY" => nil,
          # Test-environment axis. We rotate which of the three test
          # vars carries the marker so the in-test detection is
          # exercised across all of `RACK_ENV` / `RAILS_ENV` /
          # `APP_ENV` rather than just the first.
          **test_env_overrides(in_test_env: in_test_env, rng: rng),
          # Debug mode is irrelevant to Property 3; pin it off so a
          # leaking outer env can't accidentally route delivery
          # through the logger branch.
          "BETTER_AUTH_TELEMETRY_DEBUG" => nil,
          "OPEN_AUTH_TELEMETRY_DEBUG" => nil,
          # Endpoint is irrelevant because we always supply a
          # `custom_track`; pin it off explicitly so the no-delivery
          # short-circuit decision is unambiguous.
          "BETTER_AUTH_TELEMETRY_ENDPOINT" => nil,
          "OPEN_AUTH_TELEMETRY_ENDPOINT" => nil
        }
      end

      def test_env_overrides(in_test_env:, rng:)
        keys = %w[RACK_ENV RAILS_ENV APP_ENV]
        if in_test_env
          marker_key = keys.sample(random: rng)
          keys.each_with_object({}) { |k, h| h[k] = (k == marker_key) ? "test" : nil }
        else
          keys.each_with_object({}) { |k, h| h[k] = nil }
        end
      end

      def build_options(options_enabled)
        case options_enabled
        when nil then {}
        when true then {telemetry: {enabled: true}}
        when false then {telemetry: {enabled: false}}
        end
      end

      def format_label(options_enabled:, env_truthy:, in_test_env:, skip_test_check:, env_overrides:)
        "options_enabled=#{options_enabled.inspect} " \
          "env_truthy=#{env_truthy} " \
          "(BETTER_AUTH_TELEMETRY=#{env_overrides["BETTER_AUTH_TELEMETRY"].inspect}) " \
          "in_test_env=#{in_test_env} " \
          "skip_test_check=#{skip_test_check}"
      end
    end
  end
end
