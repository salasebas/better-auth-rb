# frozen_string_literal: true

require_relative "../../test_helper"
require "better_auth/telemetry/env"
require_relative "../support/env_helpers"

# Property-based tests for the telemetry env wrapper.
#
# These properties drive the same code paths exercised by the unit
# tests in `test/telemetry/env_test.rb`, but instead of pinning a
# handful of representative values they sweep a generated input space
# (deterministic across a fixed `Random` seed) and assert the
# specification rule holds for every input.
#
# `prop_check` is not currently bundled in this package, so the
# properties run as deterministic Minitest cases backed by a seeded
# generator. The structure is intentionally close to a `prop_check`
# property so that swapping in `prop_check` later (gated by the
# conditional require in `test/test_helper.rb`) is mechanical: each
# property body is a single block that asserts a universal rule for
# one generated input.
#
# Per design (`design.md` § Correctness Properties), each property
# runs ≥100 iterations. The iteration count and seed are exposed as
# constants so a failing run can be reproduced byte-for-byte.
module BetterAuth
  module Telemetry
    class EnvPropertyTest < Minitest::Test
      include BetterAuth::Telemetry::Test::EnvHelpers

      Env = BetterAuth::Telemetry::Env

      # Number of randomised iterations per property. Bumped above the
      # design floor (100) to give the alphabet a fair shake while
      # still keeping the test fast.
      ITERATIONS = 200

      # Fixed seed so a counter-example can be reproduced verbatim by
      # rerunning the file. If you change the seed, write the new seed
      # into the test (do not rely on the global default).
      SEED = 0xBA11_BA11

      # Telemetry env vars that share the dual-prefix resolution path.
      # Property 1 must hold for each of these names; we exercise all
      # three to guard against an accidental hard-coded prefix.
      TELEMETRY_VAR_NAMES = [
        "BETTER_AUTH_TELEMETRY",
        "BETTER_AUTH_TELEMETRY_DEBUG",
        "BETTER_AUTH_TELEMETRY_ENDPOINT"
      ].freeze

      # Edge-case strings the spec calls out explicitly for the truthy
      # classifier. Every case in this list is asserted before random
      # generation kicks in so the property fails loudly on a regression
      # against a documented value.
      TRUTHY_EDGE_CASES = [
        # falsy: empty / "0" / casing-insensitive "false"
        "",
        "0",
        "false",
        "FALSE",
        "False",
        "FaLsE",
        # truthy: any other non-empty string
        "1",
        "00",
        "yes",
        "true",
        "TRUE",
        " ",
        "0 ",          # not the literal "0"
        " false",      # not casecmp("false")
        "falsey",
        "no"           # NB: spec only special-cases "0" and "false"
      ].freeze

      # Helper: enumerate the 9 (nil | "" | non-empty-string) ×
      # (nil | "" | non-empty-string) corners of the input space for
      # Property 1 once, then top up with seeded random pairs to reach
      # `ITERATIONS` total samples.
      def each_env_value_pair(rng)
        deterministic = [nil, ""].product([nil, ""]) +
          [nil, ""].product([random_non_empty(rng)]) +
          [random_non_empty(rng)].product([nil, ""]) +
          [[random_non_empty(rng), random_non_empty(rng)]]

        deterministic.each { |pair| yield(*pair) }

        remaining = ITERATIONS - deterministic.length
        remaining.times do
          yield(random_env_value(rng), random_env_value(rng))
        end
      end

      # Three-way generator: nil, "", or a non-empty string. Mirrors
      # the input space defined by Property 1 in the design.
      def random_env_value(rng)
        case rng.rand(3)
        when 0 then nil
        when 1 then ""
        else random_non_empty(rng)
        end
      end

      # Generate a non-empty printable ASCII string. Length 1..16 keeps
      # generated values readable in failure messages.
      def random_non_empty(rng)
        length = 1 + rng.rand(16)
        Array.new(length) { rng.rand(33..126).chr(Encoding::UTF_8) }.join
      end

      # Generator for arbitrary strings used by Property 2. Mixes
      # printable ASCII, the empty string, and the documented edge
      # cases so the random sweep never drifts away from the spec
      # boundary values.
      def random_truthy_input(rng)
        case rng.rand(10)
        when 0 then ""
        when 1 then "0"
        when 2 then %w[false False FALSE FaLsE].sample(random: rng)
        else random_non_empty(rng)
        end
      end

      # ---------------------------------------------------------------------
      # Property 1: Environment variable resolution honors `OPEN_AUTH_*`
      # precedence.
      #
      # For any pair (open_auth_value, better_auth_value) where each is
      # independently nil, "", or a non-empty string, the value resolved by
      # `BetterAuth::Telemetry::Env.get(name)` (which delegates to
      # `BetterAuth::Env.get`) SHALL equal:
      #
      #   - open_auth_value when open_auth_value is non-empty,
      #   - else better_auth_value when better_auth_value is non-empty,
      #   - else nil.
      #
      # Validates: Requirements 3.1, 3.5, 3.7
      # ---------------------------------------------------------------------
      def test_property_1_open_auth_precedence
        rng = Random.new(SEED)

        TELEMETRY_VAR_NAMES.each do |name|
          open_auth_name = name.sub("BETTER_AUTH_", "OPEN_AUTH_")

          each_env_value_pair(rng) do |open_auth_value, better_auth_value|
            expected =
              if !open_auth_value.nil? && !open_auth_value.empty?
                open_auth_value
              elsif !better_auth_value.nil? && !better_auth_value.empty?
                better_auth_value
              end

            with_env(
              open_auth_name => open_auth_value,
              name => better_auth_value
            ) do
              actual = Env.get(name)
              message =
                "Env.get(#{name.inspect}) violated OPEN_AUTH_* precedence " \
                "for #{open_auth_name}=#{open_auth_value.inspect}, " \
                "#{name}=#{better_auth_value.inspect}"

              if expected.nil?
                assert_nil(actual, message)
              else
                assert_equal(expected, actual, message)
              end
            end
          end
        end
      end

      # ---------------------------------------------------------------------
      # Property 2: Truthy_Env_Value classification rule.
      #
      # For any string s, `BetterAuth::Telemetry::Env.truthy?(s)` SHALL be
      # true if and only if s is non-empty AND s != "0" AND
      # s.casecmp("false") != 0.
      #
      # Validates: Requirements 3.6
      # ---------------------------------------------------------------------
      def test_property_2_truthy_classification
        rng = Random.new(SEED)

        # Edge cases first — these are part of the spec's documented
        # behavior and a regression here is more interesting than any
        # random failure.
        TRUTHY_EDGE_CASES.each do |s|
          assert_truthy_matches_spec(s)
        end

        remaining = ITERATIONS - TRUTHY_EDGE_CASES.length
        remaining = 0 if remaining.negative?
        remaining.times do
          assert_truthy_matches_spec(random_truthy_input(rng))
        end
      end

      private

      # Compute the spec's truthy rule directly from `s` and assert
      # `Env.truthy?(s)` agrees. This deliberately re-derives the
      # expectation from the spec's prose rather than the
      # implementation so the property is meaningful.
      def assert_truthy_matches_spec(s)
        expected = !s.empty? && s != "0" && s.casecmp("false") != 0
        actual = Env.truthy?(s)

        assert_equal(
          expected,
          actual,
          "Env.truthy?(#{s.inspect}) violated the truthy classification rule"
        )
      end
    end
  end
end
