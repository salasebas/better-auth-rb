# frozen_string_literal: true

require "json"

require_relative "../../test_helper"

# Property-based test for the JSON round-trip preservation invariant
# — Property 17 of `design.md` § Correctness Properties.
#
# Property 17 — JSON round-trip preserves event content
#   *For any* event `E` whose `:type` is a `String` and whose
#   `:payload` is a `Hash` with JSON-encodable values (no `Proc`,
#   no cycles), the round-trip `JSON.parse(JSON.generate(E))` SHALL
#   deep-equal `E` after normalizing hash keys to `String`s.
#
# `prop_check` is not currently bundled in this package, so the
# property runs as a deterministic Minitest case backed by a seeded
# generator. The structure is intentionally close to a `prop_check`
# property so that swapping in `prop_check` later (gated by the
# conditional require in `test/test_helper.rb`) is mechanical: each
# iteration runs the same universal assertion against one generated
# event tuple.
#
# Per design (`design.md` § Correctness Properties), the property
# runs ≥100 iterations. The iteration count and seed are exposed as
# constants so a failing run can be reproduced byte-for-byte.
#
# Why the property is worth testing as a property rather than a
# handful of examples:
#
#   - The publisher is free to assemble events from a mix of
#     symbol-keyed and string-keyed hashes (see the symbol/string
#     normalization step in `Publisher#publish`). Property 17 pins
#     down the wire-level guarantee that, regardless of how the
#     event was assembled, the JSON written by `JSON.generate` is
#     re-parseable into a structurally-identical Ruby value when
#     symbol keys are normalized to strings.
#   - The payload generator builds nested hashes and arrays of
#     arbitrary depth (bounded for runtime), so the property
#     simultaneously covers scalar leaves, nested hashes, arrays
#     of hashes, hashes of arrays, and mixed shapes — none of
#     which is feasible to enumerate by hand.
#
# Validates: Requirements 6.1, 6.3, 20.4
module BetterAuth
  module Telemetry
    class JsonRoundTripPropertyTest < Minitest::Test
      # Total number of randomized iterations. The design floor is
      # 100; we run a few extra to soak the variation across the
      # generator's depth / branching factor (scalar leaves, nested
      # hashes, arrays-of-hashes, mixed shapes).
      ITERATIONS = 150

      # Fixed seed so a counter-example can be reproduced verbatim
      # by rerunning the file. If you change the seed, write the new
      # seed into the test (do not rely on the global default).
      SEED = 0x1F50_7811

      # Maximum nesting depth for generated payloads. Bounded so the
      # property runs in roughly constant time per iteration; deep
      # enough that nested-in-nested hashes / arrays / hashes-in-
      # arrays / arrays-in-hashes are all reachable.
      MAX_PAYLOAD_DEPTH = 4

      # Maximum number of keys per generated hash and entries per
      # generated array. Kept small so failure messages remain
      # readable while still allowing variation across iterations.
      MAX_HASH_KEYS = 4
      MAX_ARRAY_ENTRIES = 4

      # Alphabet for generated `String` scalars and hash keys. ASCII
      # letters and digits keep the values JSON-safe (no escape
      # sequences) and high-cardinality enough that an accidental
      # collision with structural punctuation is vanishingly
      # unlikely.
      STRING_ALPHABET = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a

      # Bound on the absolute value of generated `Integer` scalars.
      # Wide enough that multi-digit values appear in most
      # iterations.
      INTEGER_BOUND = 1_000_000

      # ---------------------------------------------------------------------
      # Property 17: JSON round-trip preserves event content.
      #
      # For any randomly-generated event tuple
      # `(type, anonymousId, payload)`:
      #
      #   1. `JSON.generate(event)` succeeds without raising,
      #   2. `JSON.parse(JSON.generate(event))` deep-equals
      #      `stringify_keys(event)`,
      #   3. The string-normalized round-trip is itself a fixed
      #      point: re-running `stringify_keys` on it returns the
      #      same value (a sanity check that string normalization is
      #      idempotent for JSON-parsed output, which it must be
      #      since `JSON.parse` already returns string keys).
      #
      # Validates: Requirements 6.1, 6.3, 20.4
      # ---------------------------------------------------------------------
      def test_property_17_json_round_trip_preserves_event_content
        rng = Random.new(SEED)

        ITERATIONS.times do |i|
          event = generate_event(rng)
          assert_round_trip_holds(event, iteration: i)
        end
      end

      private

      # Drive a single iteration of the property: generate the
      # round-trip pair and assert all three invariants.
      def assert_round_trip_holds(event, iteration:)
        json = nil
        begin
          json = JSON.generate(event)
        rescue => e
          flunk(
            "iteration #{iteration}: JSON.generate raised #{e.class}: #{e.message}; " \
            "event=#{event.inspect}"
          )
        end

        parsed = JSON.parse(json)
        normalized = stringify_keys(event)

        assert_equal(
          normalized,
          parsed,
          "iteration #{iteration}: JSON.parse(JSON.generate(event)) must deep-equal " \
          "stringify_keys(event); event=#{event.inspect}, json=#{json.inspect}"
        )

        # Idempotence sanity check: re-stringifying the parsed value
        # is a no-op. JSON.parse already returns string keys, so this
        # must always hold; failing here would indicate a bug in the
        # `stringify_keys` helper itself.
        assert_equal(
          parsed,
          stringify_keys(parsed),
          "iteration #{iteration}: stringify_keys must be idempotent on JSON.parse output; " \
          "parsed=#{parsed.inspect}"
        )
      end

      # Recursively convert every `Symbol` hash key to its `String`
      # equivalent. Walks `Hash` and `Array` containers; leaves
      # scalars (Integer, String, true, false, nil) untouched.
      #
      # This mirrors the normalization rule from Property 17:
      # symbol-keyed Ruby hashes are not preserved by JSON, so the
      # property compares the parsed output against the input after
      # this normalization step.
      def stringify_keys(value)
        case value
        when Hash
          value.each_with_object({}) do |(k, v), acc|
            acc[k.is_a?(Symbol) ? k.to_s : k] = stringify_keys(v)
          end
        when Array
          value.map { |v| stringify_keys(v) }
        else
          value
        end
      end

      # Build a random event hash matching the shape Property 17
      # ranges over: `:type` is a `String`, `:anonymousId` is a
      # `String`, and `:payload` is a `Hash` of arbitrary
      # JSON-encodable depth. Keys are emitted as Ruby `Symbol`s on
      # the top level so the round-trip exercises the symbol-to-
      # string normalization branch of the comparison; the payload
      # contents mix symbol and string hash keys so the recursive
      # branch is exercised too.
      def generate_event(rng)
        {
          type: generate_string(rng),
          anonymousId: generate_string(rng),
          payload: generate_hash(rng, depth: 0)
        }
      end

      # Pick one of the five JSON-encodable scalar shapes uniformly
      # at random and materialize a fresh value. The five shapes
      # mirror the design's enumeration of Ruby's JSON-encodable
      # scalars: `Integer`, `String`, `true`, `false`, `nil`.
      def generate_scalar(rng)
        case rng.rand(5)
        when 0 then generate_integer(rng)
        when 1 then generate_string(rng)
        when 2 then true
        when 3 then false
        end
      end

      # Generate a non-empty random alphanumeric `String` between 1
      # and 16 characters long.
      def generate_string(rng)
        length = 1 + rng.rand(16)
        Array.new(length) { STRING_ALPHABET.sample(random: rng) }.join
      end

      # Generate a signed `Integer` in
      # `[-INTEGER_BOUND, INTEGER_BOUND]`.
      def generate_integer(rng)
        rng.rand(-INTEGER_BOUND..INTEGER_BOUND)
      end

      # Generate a random JSON-encodable value at the given depth.
      # Once `depth` reaches `MAX_PAYLOAD_DEPTH` the generator only
      # emits scalars to guarantee termination. Below the limit the
      # generator picks among scalar / hash / array branches with
      # decreasing weight on containers as depth increases, which
      # keeps the average tree size small while still allowing deep
      # paths to appear occasionally.
      def generate_value(rng, depth:)
        return generate_scalar(rng) if depth >= MAX_PAYLOAD_DEPTH

        # Bias toward scalars so trees terminate quickly.
        case rng.rand(10)
        when 0..5 then generate_scalar(rng)
        when 6..7 then generate_hash(rng, depth: depth + 1)
        else generate_array(rng, depth: depth + 1)
        end
      end

      # Generate a random `Hash` whose keys are a mix of `Symbol`s
      # and `String`s (so the property exercises both branches of
      # the recursive `stringify_keys` normalization) and whose
      # values are recursively generated `JSON-encodable` values at
      # the next depth level.
      def generate_hash(rng, depth:)
        key_count = rng.rand(MAX_HASH_KEYS + 1)
        used = {}
        result = {}

        key_count.times do
          # Mix symbol and string keys roughly evenly. The hash
          # comparison after normalization must treat both forms
          # identically, so seeding both shapes is essential.
          base = generate_string(rng)
          key = (rng.rand < 0.5) ? base.to_sym : base

          # Skip duplicate-after-normalization keys so the resulting
          # hash has a deterministic comparison; otherwise a symbol
          # key and a same-spelled string key would collide after
          # `stringify_keys` and the assertion would compare
          # different cardinalities.
          normalized_key = key.is_a?(Symbol) ? key.to_s : key
          next if used.key?(normalized_key)
          used[normalized_key] = true

          result[key] = generate_value(rng, depth: depth)
        end

        result
      end

      # Generate a random `Array` whose entries are recursively
      # generated `JSON-encodable` values at the next depth level.
      def generate_array(rng, depth:)
        length = rng.rand(MAX_ARRAY_ENTRIES + 1)
        Array.new(length) { generate_value(rng, depth: depth) }
      end
    end
  end
end
