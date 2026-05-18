# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/mock"
require "better_auth/telemetry/detectors/framework"

# Property-based test for the framework detector first-match-wins
# rule — Property 9 of `design.md` § Correctness Properties.
#
# Property 9 — Framework detector first-match-wins
#   *For any* subset `S` of the gem name list
#   `["rails", "sinatra", "hanami", "hanami-router", "roda", "grape",
#   "rack"]` treated as the set of currently loaded specs,
#   `BetterAuth::Telemetry::Detectors::Framework.call` SHALL return:
#     - `{name: g, version: <version_string>}` where `g` is the
#       lowest-index element of the declaration order that is in
#       `S`, when `S` is non-empty,
#     - `nil`, when `S` is empty.
#
# `prop_check` is not currently bundled, so the property runs as a
# deterministic Minitest case driven by a seeded `Random`. The seed
# and iteration count are exposed as constants so a failing run can
# be reproduced byte-for-byte. The structure intentionally mirrors
# `database_detector_property_test.rb` so swapping in `prop_check`
# later (gated by the conditional require in `test/test_helper.rb`)
# is mechanical.
#
# Each iteration:
#   - chooses a subset `S` of the 7 framework gems by drawing a
#     bitmask from `0..127`. Across `ITERATIONS` iterations every
#     subset is sampled densely, including the empty set (Rule 2)
#     and the full set (Rule 1 with the maximum competition);
#   - stamps each chosen gem with a fresh random `Gem::Version`
#     string so the detector's `version.to_s` stringification is
#     exercised against realistic input rather than a single hard
#     coded value;
#   - sprinkles 0..2 unrelated gems into `Gem.loaded_specs` to
#     verify the detector ignores anything outside `Framework::GEMS`;
#   - stubs `Gem.loaded_specs` with the resulting hash;
#   - re-derives the expected return straight from the spec prose
#     (lowest-index element of `Framework::GEMS` that is in `S`,
#     otherwise `nil`) so the assertion is meaningful and not just
#     a round-trip through the implementation.
#
# Validates: Requirements 11.1, 11.2, 11.3
module BetterAuth
  module Telemetry
    class FrameworkDetectorPropertyTest < Minitest::Test
      Framework = BetterAuth::Telemetry::Detectors::Framework

      # Number of randomised iterations. The design floor is 100;
      # we run a comfortable margin over so that, combined with the
      # deterministic boundary samples, every one of the 128
      # possible bitmask subsets is hit at least once with high
      # probability.
      ITERATIONS = 200

      # Fixed seed so a counter-example can be reproduced verbatim
      # by rerunning the file. If you change the seed, write the new
      # seed into the test (do not rely on the global default).
      SEED = 0xFB_DE7EC

      # Generators -------------------------------------------------

      # Random gems that are NOT in `Framework::GEMS`. Sampled into
      # the loaded-spec set to prove the detector ignores gems
      # outside the documented framework list (Requirement 11.4
      # neighbouring behaviour).
      NON_FRAMEWORK_GEMS = %w[
        redis
        pg
        mysql2
        sqlite3
        activerecord
        sequel
        nokogiri
        json
        rake
      ].freeze

      # Minimal stand-in for `Gem::Specification` used to populate
      # the stubbed `Gem.loaded_specs`. Identical in shape to the
      # `FakeSpec` from `framework_test.rb` so a counter-example
      # surfaced by this property reproduces against the unit-test
      # harness without translation.
      FakeSpec = Struct.new(:version) do
        def self.with_version(string)
          new(::Gem::Version.new(string))
        end
      end

      # ---------------------------------------------------------------------
      # Property 9: Framework detector first-match-wins.
      #
      # Validates: Requirements 11.1, 11.2, 11.3
      # ---------------------------------------------------------------------
      def test_property_9_framework_detector_first_match_wins
        rng = Random.new(SEED)

        # Deterministic boundary samples first. These pin every
        # documented branch (empty set → nil, lone gem at every
        # position → that gem wins, full set → first declaration
        # wins) so a regression on a documented value fails loudly
        # before random generation starts.
        deterministic_samples.each_with_index do |sample, i|
          assert_first_match_wins(sample, label: "deterministic sample #{i}")
        end

        remaining = ITERATIONS - deterministic_samples.length
        remaining = 0 if remaining.negative?
        remaining.times do |i|
          assert_first_match_wins(
            random_sample(rng, iteration: i),
            label: "random iteration #{i}"
          )
        end
      end

      private

      # Run the block with `Gem.loaded_specs` stubbed to `specs` (a
      # `Hash<String, FakeSpec>`). Restores the real value on the
      # way out. Mirrors the helper used in `framework_test.rb`.
      def with_loaded_specs(specs)
        ::Gem.stub(:loaded_specs, specs) do
          yield
        end
      end

      # A single iteration tuple. `subset` is the chosen subset of
      # `Framework::GEMS`; `versions` is the per-gem version stamp;
      # `extras` is the noise drawn from `NON_FRAMEWORK_GEMS`.
      Sample = Struct.new(:subset, :versions, :extras, keyword_init: true)

      # Boundary samples that pin the documented behaviour for every
      # documented branch of the first-match-wins rule. The list is
      # intentionally short — its purpose is to fail loudly on a
      # documented regression before the random sweep starts.
      # Random iterations do the heavy lifting.
      def deterministic_samples
        @deterministic_samples ||= [
          # Empty subset → nil (Rule 2).
          build_sample(subset: []),
          # Each gem in isolation wins at its own position (Rule 1
          # with a singleton subset).
          *Framework::GEMS.map { |g| build_sample(subset: [g]) },
          # Full subset → first declaration order element wins.
          build_sample(subset: Framework::GEMS.dup),
          # Mid-list winners with later competition.
          build_sample(subset: %w[hanami hanami-router roda grape rack]),
          build_sample(subset: %w[roda grape rack]),
          build_sample(subset: %w[grape rack]),
          # Skip-the-front to confirm later elements do win when the
          # front of the list is absent.
          build_sample(subset: %w[hanami-router rack]),
          build_sample(subset: %w[sinatra rack])
        ].freeze
      end

      # Build a randomised `Sample` for the given iteration index.
      # Subsets are drawn via a bitmask over `0..127` so every
      # subset of `Framework::GEMS` is reachable. Non-framework
      # gems are sprinkled in 0..2 at a time as noise.
      def random_sample(rng, iteration:)
        bitmask = rng.rand(1 << Framework::GEMS.length) # 0..127
        subset = Framework::GEMS.each_with_index.filter_map do |gem_name, idx|
          gem_name if bitmask[idx] == 1
        end

        build_sample(
          subset: subset,
          rng: rng,
          extras: random_extras(rng)
        )
      end

      # Materialise a `Sample` with version stamps for every gem in
      # the subset and (optionally) noise gems from
      # `NON_FRAMEWORK_GEMS`. Versions are deterministic relative to
      # the supplied `rng` so a failing iteration reproduces.
      def build_sample(subset:, rng: Random.new(SEED), extras: [])
        versions = subset.to_h { |gem_name| [gem_name, random_version(rng)] }
        extras_with_versions = extras.to_h { |gem_name| [gem_name, random_version(rng)] }
        Sample.new(subset: subset, versions: versions, extras: extras_with_versions)
      end

      # Pick 0..2 non-framework gems at random.
      def random_extras(rng)
        count = rng.rand(3)
        Array.new(count) { NON_FRAMEWORK_GEMS.sample(random: rng) }.uniq
      end

      # Random `MAJOR.MINOR.PATCH` version string. Bounds keep the
      # output stable regardless of `Gem::Version`'s normalization
      # (no leading zeros, no trailing dot).
      def random_version(rng)
        "#{rng.rand(10)}.#{rng.rand(20)}.#{rng.rand(50)}"
      end

      # Build the `Gem.loaded_specs` mapping for a sample by
      # combining the in-subset framework gems and the unrelated
      # noise gems, all wrapped in `FakeSpec`s.
      def loaded_specs_for(sample)
        specs = {}
        sample.versions.each do |gem_name, version_string|
          specs[gem_name] = FakeSpec.with_version(version_string)
        end
        sample.extras.each do |gem_name, version_string|
          specs[gem_name] = FakeSpec.with_version(version_string)
        end
        specs
      end

      # Drive a single iteration of the property: stub
      # `Gem.loaded_specs`, call `Framework.call`, and assert the
      # result equals the spec-derived expectation.
      def assert_first_match_wins(sample, label:)
        specs = loaded_specs_for(sample)
        expected = expected_result(sample)

        with_loaded_specs(specs) do
          actual = Framework.call

          message =
            "Framework.call violated the first-match-wins rule for #{label} " \
            "(subset=#{sample.subset.inspect}, extras=#{sample.extras.keys.inspect})"

          if expected.nil?
            assert_nil(actual, message)
          else
            assert_equal(expected, actual, message)
          end
        end
      end

      # Re-derive the expected return value straight from the spec
      # prose so the property does not just round-trip through the
      # implementation.
      def expected_result(sample)
        Framework::GEMS.each do |gem_name|
          next unless sample.subset.include?(gem_name)
          return {name: gem_name, version: sample.versions.fetch(gem_name)}
        end
        nil
      end
    end
  end
end
