# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/mock"
require "better_auth"
require "better_auth/telemetry/detectors/database"
require "better_auth/telemetry/options"

# Property-based test for the database detector precedence chain —
# Property 8 of `design.md` § Correctness Properties.
#
# Property 8 — Database detector precedence chain
#   *For any* tuple
#   `(context_database, configuration_database, loaded_gem_set)`,
#   `BetterAuth::Telemetry::Detectors::Database.call` SHALL return:
#     1. `{name: context_database, version: nil}` when
#        `context_database` is a non-empty `String`, otherwise
#     2. `{name: <identifier_string>, version: nil}` when
#        `configuration_database` maps to a known
#        `BetterAuth::Adapters::*` identifier, otherwise
#     3. `{name: gem_name, version: <version_string>}` for the
#        lowest-index gem in
#        `["sequel", "pg", "mysql2", "sqlite3", "activerecord",
#        "mongoid", "mongo", "rom-sql"]` that is in
#        `loaded_gem_set`, otherwise
#     4. `nil`.
#
# `prop_check` is not currently bundled, so the property runs as a
# deterministic Minitest case driven by a seeded `Random`. The seed
# and iteration count are exposed as constants so a failing run can
# be reproduced byte-for-byte. The structure intentionally mirrors
# `environment_classifier_property_test.rb` so swapping in
# `prop_check` later (gated by the conditional require in
# `test/test_helper.rb`) is mechanical.
#
# Each iteration:
#   - draws `context_database` from a fixed alphabet that includes
#     `nil`, `""`, the symbol-shaped strings the detector is
#     expected to honor (`"postgres"`, `"mysql"`), the canonical
#     custom override (`"custom-db"`), and a fresh random string
#     stamped per-iteration so the override branch is sampled
#     across an unbounded value space;
#   - draws `configuration_database` from a fixed alphabet of known
#     adapter symbols plus an unknown symbol so the second precedence
#     rule's fall-through branch is exercised;
#   - draws `loaded_gem_set` as a random subset of the fallback gem
#     list plus a sprinkling of unrelated gems, ensuring both the
#     "earlier gem wins" and "non-fallback gems are ignored"
#     behaviours are covered;
#   - alternates the context shape between a {NormalizedContext} and
#     a raw symbol-keyed hash so the detector's hash-tolerance is
#     exercised every other iteration;
#   - alternates the options shape between a real
#     {BetterAuth::Configuration} and a raw symbol-keyed hash for
#     the same reason;
#   - stubs `Gem.loaded_specs` with the generated set (using the
#     same `FakeSpec` shape as the unit tests);
#   - re-derives the expected return straight from the spec prose,
#     not from the implementation, so the assertion is meaningful.
#
# Validates: Requirements 10.1, 10.2, 10.3, 10.4
module BetterAuth
  module Telemetry
    class DatabaseDetectorPropertyTest < Minitest::Test
      Database = BetterAuth::Telemetry::Detectors::Database
      NormalizedContext = BetterAuth::Telemetry::NormalizedContext

      # Number of randomised iterations. The design floor is 100;
      # we run a comfortable margin over to soak the variation
      # across context shape, options shape, and gem-subset choice.
      ITERATIONS = 200

      # Fixed seed so a counter-example can be reproduced verbatim
      # by rerunning the file. If you change the seed, write the new
      # seed into the test (do not rely on the global default).
      SEED = 0xDB_DE7EC

      # Generators -------------------------------------------------

      # Fixed alphabet for `context_database`. The first entry is
      # `nil` (override absent), the second is `""` (override is an
      # empty string and SHALL be ignored per the implementation
      # contract), and the rest exercise a mix of canonical and
      # opaque override values. A fresh random string is drawn per
      # iteration in addition to the fixed entries so the override
      # branch is sampled beyond the closed alphabet.
      CONTEXT_DATABASE_FIXED = [nil, "", "postgres", "mysql", "custom-db"].freeze

      # Fixed alphabet for `configuration_database`. Mirrors the
      # `ADAPTER_SYMBOLS` keys plus `nil` (no configuration value)
      # and one symbol that is intentionally not in the map so the
      # fall-through branch to the gem fallback is exercised.
      CONFIGURATION_DATABASE_DOMAIN = [
        nil,
        :postgres,
        :mysql,
        :sqlite,
        :memory,
        :unknown_symbol
      ].freeze

      # Random gems that are NOT in `Database::GEM_FALLBACKS`.
      # Sampled into the loaded-spec set to prove the detector
      # ignores gems outside the documented fallback list.
      NON_FALLBACK_GEMS = %w[
        rack
        rails
        sinatra
        redis
        json
        nokogiri
        webmock
      ].freeze

      # Alphabet used to mint random override strings per iteration.
      # ASCII letters / digits keep the secret JSON-safe and
      # high-cardinality enough that a collision with the closed
      # alphabet is negligible at our iteration count.
      RANDOM_STRING_ALPHABET = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a

      # Minimal stand-in for `Gem::Specification` used to populate
      # the stubbed `Gem.loaded_specs`. Identical in shape to the
      # `FakeSpec` from `database_test.rb` so a counter-example
      # surfaced by this property reproduces against the unit-test
      # harness without translation.
      FakeSpec = Struct.new(:version) do
        def self.with_version(string)
          new(::Gem::Version.new(string))
        end
      end

      # ---------------------------------------------------------------------
      # Property 8: Database detector precedence chain.
      #
      # Validates: Requirements 10.1, 10.2, 10.3, 10.4
      # ---------------------------------------------------------------------
      def test_property_8_database_detector_precedence_chain
        rng = Random.new(SEED)

        # Deterministic boundary samples first. These exercise every
        # documented branch of the precedence chain (context override,
        # configuration adapter, gem fallback first-match, and the
        # all-empty fall-through to `nil`) before random generation
        # starts so a regression on a documented value fails loudly.
        deterministic_samples.each_with_index do |sample, i|
          assert_precedence_holds(sample, label: "deterministic sample #{i}")
        end

        remaining = ITERATIONS - deterministic_samples.length
        remaining = 0 if remaining.negative?
        remaining.times do |i|
          assert_precedence_holds(
            random_sample(rng, iteration: i),
            label: "random iteration #{i}"
          )
        end
      end

      private

      # Run the block with `Gem.loaded_specs` stubbed to `specs` (a
      # `Hash<String, FakeSpec>`). Restores the real value on the
      # way out. Mirrors the helper used in `database_test.rb`.
      def with_loaded_specs(specs)
        ::Gem.stub(:loaded_specs, specs) do
          yield
        end
      end

      # A single iteration tuple. `context_shape` and `options_shape`
      # are sampled per-iteration to alternate between the
      # `NormalizedContext` / `Configuration` (production) and raw
      # hash (test seam) input shapes.
      Sample = Struct.new(
        :context_database,
        :configuration_database,
        :loaded_gem_set,
        :context_shape,
        :options_shape,
        keyword_init: true
      )

      # Boundary samples that pin the documented behaviour for every
      # branch of the precedence ladder. The list is intentionally
      # short — its purpose is to fail loudly on a documented
      # regression before the random sweep starts. Random iterations
      # do the heavy lifting.
      def deterministic_samples
        @deterministic_samples ||= [
          # Rule 4: nothing matches → nil
          Sample.new(
            context_database: nil,
            configuration_database: nil,
            loaded_gem_set: {},
            context_shape: :normalized,
            options_shape: :configuration
          ),
          # Rule 4: empty context string is ignored, no other signal
          Sample.new(
            context_database: "",
            configuration_database: nil,
            loaded_gem_set: {},
            context_shape: :hash,
            options_shape: :hash
          ),
          # Rule 3: lone fallback gem wins
          Sample.new(
            context_database: nil,
            configuration_database: nil,
            loaded_gem_set: {"pg" => fake_spec("1.5.6")},
            context_shape: :normalized,
            options_shape: :configuration
          ),
          # Rule 3: earliest fallback gem wins among several
          Sample.new(
            context_database: nil,
            configuration_database: nil,
            loaded_gem_set: {
              "activerecord" => fake_spec("7.1.3"),
              "pg" => fake_spec("1.5.6"),
              "sequel" => fake_spec("5.78.0")
            },
            context_shape: :normalized,
            options_shape: :hash
          ),
          # Rule 2: configuration symbol resolves to identifier
          Sample.new(
            context_database: nil,
            configuration_database: :memory,
            loaded_gem_set: {"pg" => fake_spec("1.5.6")},
            context_shape: :normalized,
            options_shape: :configuration
          ),
          # Rule 2: configuration via raw hash also resolves
          Sample.new(
            context_database: nil,
            configuration_database: :sqlite,
            loaded_gem_set: {},
            context_shape: :hash,
            options_shape: :hash
          ),
          # Rule 1: context override wins over configuration + gems
          Sample.new(
            context_database: "custom-db",
            configuration_database: :postgres,
            loaded_gem_set: {"pg" => fake_spec("1.5.6")},
            context_shape: :normalized,
            options_shape: :configuration
          ),
          # Rule 1: hash-shaped context override
          Sample.new(
            context_database: "mongo",
            configuration_database: nil,
            loaded_gem_set: {"sequel" => fake_spec("5.78.0")},
            context_shape: :hash,
            options_shape: :hash
          )
        ].freeze
      end

      # Build a randomised `Sample` for the given iteration index.
      def random_sample(rng, iteration:)
        Sample.new(
          context_database: random_context_database(rng),
          configuration_database: CONFIGURATION_DATABASE_DOMAIN.sample(random: rng),
          loaded_gem_set: random_loaded_gem_set(rng),
          context_shape: [:normalized, :hash].sample(random: rng),
          options_shape: [:configuration, :hash].sample(random: rng)
        )
      end

      # Pick a context-database value. Most iterations draw from the
      # fixed alphabet so the documented values are sampled densely;
      # a fraction draws a fresh random string so the override branch
      # is exercised across an unbounded value space.
      def random_context_database(rng)
        if rng.rand(6).zero?
          random_string(rng, length: 4 + rng.rand(13))
        else
          CONTEXT_DATABASE_FIXED.sample(random: rng)
        end
      end

      # Generate a non-empty alphanumeric string of `length`
      # characters. Used both for random override values and for
      # the per-spec version stamps below.
      def random_string(rng, length:)
        Array.new(length) { RANDOM_STRING_ALPHABET.sample(random: rng) }.join
      end

      # Build a random `Gem.loaded_specs` mapping. Each fallback gem
      # is included with probability ~½ and stamped with a fresh
      # random `Gem::Version`. A small handful of non-fallback gems
      # is sprinkled in to verify the detector ignores anything not
      # listed in `Database::GEM_FALLBACKS`.
      def random_loaded_gem_set(rng)
        specs = {}
        Database::GEM_FALLBACKS.each do |gem_name|
          next if rng.rand(2).zero?
          specs[gem_name] = fake_spec(random_version(rng))
        end
        # 0..2 random non-fallback gems
        rng.rand(3).times do
          gem_name = NON_FALLBACK_GEMS.sample(random: rng)
          specs[gem_name] = fake_spec(random_version(rng))
        end
        specs
      end

      # Build a `Gem::Version`-stamped FakeSpec. Versions follow the
      # canonical `MAJOR.MINOR.PATCH` shape so the detector's
      # `version.to_s` stringification is exercised against realistic
      # input.
      def fake_spec(version_string)
        FakeSpec.with_version(version_string)
      end

      # Random `MAJOR.MINOR.PATCH` version string. Bounds keep the
      # output stable regardless of `Gem::Version`'s normalization
      # (no leading zeros, no trailing dot).
      def random_version(rng)
        "#{rng.rand(10)}.#{rng.rand(20)}.#{rng.rand(50)}"
      end

      # Drive a single iteration of the property: build the
      # configured options/context, stub `Gem.loaded_specs`, call
      # `Database.call`, and assert the result equals the
      # spec-derived expectation.
      def assert_precedence_holds(sample, label:)
        options = build_options(sample.configuration_database, sample.options_shape)
        context = build_context(sample.context_database, sample.context_shape)
        expected = expected_result(
          context_database: sample.context_database,
          configuration_database: sample.configuration_database,
          loaded_gem_set: sample.loaded_gem_set
        )

        with_loaded_specs(sample.loaded_gem_set) do
          actual = Database.call(options, context)

          message =
            "Database.call violated the precedence rule for #{label} " \
            "(sample=#{sample.to_h.inspect})"

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
      def expected_result(context_database:, configuration_database:, loaded_gem_set:)
        # Rule 1: non-empty String context override.
        if context_database.is_a?(String) && !context_database.empty?
          return {name: context_database, version: nil}
        end

        # Rule 2: configuration symbol maps to a known adapter id.
        if configuration_database.is_a?(Symbol) && Database::ADAPTER_SYMBOLS.key?(configuration_database)
          return {name: Database::ADAPTER_SYMBOLS[configuration_database], version: nil}
        end

        # Rule 3: lowest-index gem in GEM_FALLBACKS that is loaded.
        Database::GEM_FALLBACKS.each do |gem_name|
          spec = loaded_gem_set[gem_name]
          next if spec.nil?
          return {name: gem_name, version: spec.version.to_s}
        end

        # Rule 4: no signal.
        nil
      end

      # Build the `options` argument. Alternates between a real
      # {BetterAuth::Configuration} (production path) and a raw
      # symbol-keyed hash (test seam) so the detector's
      # `configuration_database` accessor is exercised against both
      # shapes.
      def build_options(configuration_database, shape)
        case shape
        when :configuration
          BetterAuth::Configuration.new(
            secret: "0" * 40,
            database: configuration_database
          )
        when :hash
          {database: configuration_database}
        else
          raise ArgumentError, "unknown options shape: #{shape.inspect}"
        end
      end

      # Build the `context` argument. Alternates between a
      # {NormalizedContext} (production path) and a raw symbol-keyed
      # hash (test seam).
      def build_context(context_database, shape)
        case shape
        when :normalized
          NormalizedContext.from(database: context_database)
        when :hash
          {database: context_database}
        else
          raise ArgumentError, "unknown context shape: #{shape.inspect}"
        end
      end
    end
  end
end
