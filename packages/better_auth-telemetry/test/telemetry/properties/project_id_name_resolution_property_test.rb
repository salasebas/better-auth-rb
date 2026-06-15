# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/mock"
require "better_auth/telemetry/project_id"

# Property-based test for the project-name resolution chain —
# Property 15 of `design.md` § Correctness Properties.
#
# Property 15 — project_id name resolution precedence
#   *For any* tuple
#   `(app_name, locked_gems_first_name, bundler_root_basename)`
#   where each is independently `nil`, the default `"Better Auth"`,
#   or a non-empty `String`, the project name resolved by
#   `BetterAuth::Telemetry::ProjectId.resolve_project_name` SHALL be:
#
#     1. `app_name` when `app_name` is a non-empty `String` other than
#        `"Better Auth"`, otherwise
#     2. `locked_gems_first_name` when it is a non-empty `String`,
#        otherwise
#     3. `bundler_root_basename` when it is a non-empty `String`,
#        otherwise
#     4. `nil`.
#
# The `"Better Auth"` sentinel is *only* consumed by rule 1
# (`from_app_name`). For rules 2 and 3 the literal string
# `"Better Auth"` is treated like any other non-empty `String` and
# wins its rule when it gets there. This matches the upstream
# behavior — the sentinel is only meaningful when sourced from the
# host's `app_name`, not from a Gemfile.lock spec name or the
# Bundler-root basename — and is what Requirement 14.7 codifies.
#
# `prop_check` is not currently bundled in this package, so the
# property runs as a deterministic Minitest case backed by a seeded
# generator. The seed and iteration count are exposed as constants
# so a failing run can be reproduced byte-for-byte. The structure
# intentionally mirrors the other PBT files in this directory
# (notably `project_id_derivation_property_test.rb`) so swapping in
# `prop_check` later (gated by the conditional require in
# `test/test_helper.rb`) is mechanical.
#
# Each iteration:
#   - generates a tuple `(app_name, locked_gems_first_name,
#     bundler_root_basename)`, each axis independently drawn from
#     {`nil`, `"Better Auth"`, random non-empty alphanumeric String};
#   - injects `app_name` via
#     `BetterAuth::Telemetry::CurrentOptions.with_app_name(...)`
#     (always — even for the `nil` and `"Better Auth"` cases — so
#     the thread-local app name is pinned for the duration of the
#     iteration regardless of what an earlier test left behind);
#   - stubs `ProjectId.from_locked_gems` to return
#     `locked_gems_first_name` (`nil` or a `String`);
#   - stubs `ProjectId.from_bundler_root` to return
#     `bundler_root_basename` (`nil` or a `String`);
#   - calls `ProjectId.resolve_project_name`;
#   - re-derives the expected return straight from the spec prose
#     so the assertion is meaningful and not just a round-trip
#     through the implementation.
#
# Note that `resolve_project_name` does **not** consult
# `BetterAuth::Telemetry.project_id`'s memoization cache — it is
# called by the cache-miss path, not after — so this test does not
# need to call `reset_project_id!`. The cache is independent of the
# name resolution chain and is covered by Property 14.
#
# Validates: Requirements 14.7, 14.8
module BetterAuth
  module Telemetry
    class ProjectIdNameResolutionPropertyTest < Minitest::Test
      Telemetry = BetterAuth::Telemetry
      CurrentOptions = BetterAuth::Telemetry::CurrentOptions
      ProjectId = BetterAuth::Telemetry::ProjectId

      # Total number of randomized iterations. The design floor is
      # 100; we run a comfortable margin over to soak the variation
      # across the 3 × 3 × 3 = 27 axis combinations.
      ITERATIONS = 150

      # Fixed seed so a counter-example can be reproduced verbatim
      # by rerunning the file. If you change the seed, write the new
      # seed into the test (do not rely on the global default).
      SEED = 0xBEEF_F00D

      # Alphabet for randomly generated non-empty `String` inputs.
      # ASCII letters and digits keep the values JSON-safe and free
      # of byte sequences that might collide with the upstream
      # sentinel `"Better Auth"` (which contains a space, so the
      # alphabet excludes it).
      NAME_ALPHABET = (("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a).freeze

      # Per-axis input shapes. Each of the three axes (`app_name`,
      # `locked_gems_first_name`, `bundler_root_basename`) is drawn
      # independently from this set, matching the design's
      # "independently nil, default, or non-empty String" wording.
      AXIS_SHAPES = %i[nil default nonempty].freeze

      # ---------------------------------------------------------------------
      # Property 15: project_id name resolution precedence.
      #
      # Validates: Requirements 14.7, 14.8
      # ---------------------------------------------------------------------
      def test_property_15_project_id_name_resolution_precedence
        rng = Random.new(SEED)

        # Deterministic boundary samples first. These pin every one
        # of the four documented precedence rules at least once so
        # a regression on a documented branch fails loudly before
        # random generation starts. Random iterations then sweep
        # the rest of the input space.
        deterministic_samples(rng).each_with_index do |sample, i|
          assert_property_15_holds(sample, label: "deterministic sample #{i}")
        end

        remaining = ITERATIONS - deterministic_samples(rng).length
        remaining = 0 if remaining.negative?
        remaining.times do |i|
          assert_property_15_holds(
            random_sample(rng),
            label: "random iteration #{i}"
          )
        end
      end

      private

      # Per-iteration tuple. The three `*_shape` fields record which
      # axis was selected (purely for readable failure messages);
      # the three `*` fields are the post-generation values (each
      # `nil`, `"Better Auth"`, or a random non-empty `String`).
      Sample = Struct.new(
        :app_name_shape, :locked_shape, :root_shape,
        :app_name, :locked_gems_first_name, :bundler_root_basename
      )

      # Fixed boundary samples that pin every documented precedence
      # rule at least once, regardless of which random draws the
      # seed produces. The list is intentionally short — its purpose
      # is to fail loudly on a documented regression before the
      # random sweep starts. Random iterations do the heavy lifting.
      def deterministic_samples(rng)
        @deterministic_samples ||= [
          # Rule 1: app_name non-empty and not the default — wins
          # even when both downstream axes also have non-empty
          # values that would otherwise win their rules.
          Sample.new(
            app_name_shape: :nonempty,
            locked_shape: :nonempty,
            root_shape: :nonempty,
            app_name: random_string(rng),
            locked_gems_first_name: random_string(rng),
            bundler_root_basename: random_string(rng)
          ),
          # Rule 1 vs Rule 2: app_name is the default sentinel, so
          # rule 1 falls through and rule 2 (locked_gems) wins.
          Sample.new(
            app_name_shape: :default,
            locked_shape: :nonempty,
            root_shape: :nonempty,
            app_name: ProjectId::DEFAULT_APP_NAME,
            locked_gems_first_name: random_string(rng),
            bundler_root_basename: random_string(rng)
          ),
          # Rule 2 wins through rule 1 = nil.
          Sample.new(
            app_name_shape: :nil,
            locked_shape: :nonempty,
            root_shape: :nonempty,
            app_name: nil,
            locked_gems_first_name: random_string(rng),
            bundler_root_basename: random_string(rng)
          ),
          # Rule 2 with the literal "Better Auth" — locked_gems
          # returning the literal sentinel is *not* special-cased
          # downstream of `from_app_name`; the literal wins rule 2.
          Sample.new(
            app_name_shape: :nil,
            locked_shape: :default,
            root_shape: :nonempty,
            app_name: nil,
            locked_gems_first_name: ProjectId::DEFAULT_APP_NAME,
            bundler_root_basename: random_string(rng)
          ),
          # Rule 3: app_name and locked_gems both nil; bundler root
          # provides a non-empty value.
          Sample.new(
            app_name_shape: :nil,
            locked_shape: :nil,
            root_shape: :nonempty,
            app_name: nil,
            locked_gems_first_name: nil,
            bundler_root_basename: random_string(rng)
          ),
          # Rule 3 with the literal "Better Auth" — bundler root
          # returning the sentinel is *not* special-cased; the
          # literal wins rule 3.
          Sample.new(
            app_name_shape: :nil,
            locked_shape: :nil,
            root_shape: :default,
            app_name: nil,
            locked_gems_first_name: nil,
            bundler_root_basename: ProjectId::DEFAULT_APP_NAME
          ),
          # Rule 4: every axis nil — chain falls all the way through.
          Sample.new(
            app_name_shape: :nil,
            locked_shape: :nil,
            root_shape: :nil,
            app_name: nil,
            locked_gems_first_name: nil,
            bundler_root_basename: nil
          ),
          # Rule 4 again, this time with the default sentinel as the
          # app_name. `from_app_name` collapses the sentinel to
          # `nil`, locked/root are also nil, so the chain returns
          # `nil`.
          Sample.new(
            app_name_shape: :default,
            locked_shape: :nil,
            root_shape: :nil,
            app_name: ProjectId::DEFAULT_APP_NAME,
            locked_gems_first_name: nil,
            bundler_root_basename: nil
          )
        ].freeze
      end

      # Build a randomised `Sample`. Each axis is drawn
      # independently so every shape × shape × shape combination
      # from the 3 × 3 × 3 grid is reachable.
      def random_sample(rng)
        app_name_shape = AXIS_SHAPES.sample(random: rng)
        locked_shape = AXIS_SHAPES.sample(random: rng)
        root_shape = AXIS_SHAPES.sample(random: rng)

        Sample.new(
          app_name_shape: app_name_shape,
          locked_shape: locked_shape,
          root_shape: root_shape,
          app_name: value_for(app_name_shape, rng),
          locked_gems_first_name: value_for(locked_shape, rng),
          bundler_root_basename: value_for(root_shape, rng)
        )
      end

      # Materialise an axis value for the given shape. The
      # `:nonempty` branch generates a random alphanumeric string
      # that is guaranteed not to equal the upstream sentinel
      # `"Better Auth"` (the alphabet excludes spaces, so the
      # generated value can never collide with the sentinel — a
      # non-empty value drawn from this alphabet always falls into
      # the "non-empty `String` other than `Better Auth`" bucket).
      def value_for(shape, rng)
        case shape
        when :nil then nil
        when :default then ProjectId::DEFAULT_APP_NAME
        when :nonempty then random_string(rng)
        end
      end

      # Random non-empty alphanumeric `String`. Lengths in 4..16
      # are large enough for variation but small enough that the
      # test stays fast and counter-examples stay readable.
      def random_string(rng)
        length = 4 + rng.rand(13) # 4..16 inclusive
        Array.new(length) { NAME_ALPHABET.sample(random: rng) }.join
      end

      # Drive a single iteration of the property: pin the
      # thread-local app name via `with_app_name`, stub the two
      # bundler probes to the generated values, call
      # `ProjectId.resolve_project_name`, and assert the result
      # matches the spec-derived expectation.
      def assert_property_15_holds(sample, label:)
        prior_app_name = CurrentOptions.app_name

        # Always wrap in `with_app_name` — even for the `:nil`
        # axis. The block sets the thread-local to the given value
        # (`nil` for `:nil`, the literal sentinel for `:default`,
        # the random String for `:nonempty`) and restores the prior
        # value on exit. This pins the `from_app_name` input
        # regardless of whatever an earlier test left in the
        # thread-local.
        CurrentOptions.with_app_name(sample.app_name) do
          ProjectId.stub(:from_locked_gems, sample.locked_gems_first_name) do
            ProjectId.stub(:from_bundler_root, sample.bundler_root_basename) do
              actual = ProjectId.resolve_project_name
              expected = expected_project_name(sample)

              message =
                "ProjectId.resolve_project_name violated Property 15 for #{label}: " \
                "app_name_shape=#{sample.app_name_shape.inspect} (#{sample.app_name.inspect}), " \
                "locked_shape=#{sample.locked_shape.inspect} (#{sample.locked_gems_first_name.inspect}), " \
                "root_shape=#{sample.root_shape.inspect} (#{sample.bundler_root_basename.inspect}): " \
                "expected #{expected.inspect}, got #{actual.inspect}"

              # Rule 4 (`nil`) is asserted with `assert_nil` so the
              # case stays warning-free under Minitest 6, which
              # rejects `assert_equal nil, x`. Rules 1–3 use
              # `assert_equal` for an exact `String` match.
              if expected.nil?
                assert_nil actual, message
              else
                assert_equal expected, actual, message
              end
            end
          end
        end
      ensure
        # Belt-and-suspenders: `with_app_name` already restores the
        # prior value, but if a future refactor changes that
        # contract, this `ensure` keeps the rest of the suite from
        # observing thread-local state from a failed iteration.
        CurrentOptions.app_name = prior_app_name
      end

      # Re-derive the expected return value straight from the
      # Property 15 prose so the property does not just round-trip
      # through the implementation. Mirrors the four-rule chain
      # word-for-word: rule 1 only fires when app_name is a
      # non-empty String *and* not the default sentinel; rules 2
      # and 3 only require non-emptiness (the sentinel string is a
      # legitimate non-empty value at those tiers); rule 4 is the
      # `nil` fallthrough.
      def expected_project_name(sample)
        app_name = sample.app_name
        root = sample.bundler_root_basename

        if non_empty_string?(app_name) && app_name != ProjectId::DEFAULT_APP_NAME
          app_name
        elsif non_empty_string?(root)
          root
        end
      end

      # Helper mirroring the implementation's "non-empty String"
      # check used at every tier of the resolution chain.
      def non_empty_string?(value)
        value.is_a?(String) && !value.empty?
      end
    end
  end
end
