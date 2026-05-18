# frozen_string_literal: true

require_relative "../../test_helper"
require "base64"
require "digest"
require "minitest/mock"
require "better_auth/telemetry/project_id"

# Property-based test for the `project_id` derivation rules —
# Property 13 of `design.md` § Correctness Properties.
#
# Property 13 — project_id derivation rules
#   *For any* tuple `(project_name, base_url)` where each is
#   independently `nil`, the empty string, or a non-empty string,
#   after resetting the project_id cache,
#   `BetterAuth::Telemetry.project_id(base_url)` SHALL return:
#
#     1. `Base64.strict_encode64(Digest::SHA256.digest(base_url + project_name))`
#        when both `project_name` and `base_url` are non-empty,
#     2. `Base64.strict_encode64(Digest::SHA256.digest(project_name))`
#        when `project_name` is non-empty and `base_url` is nil/empty,
#     3. `Base64.strict_encode64(Digest::SHA256.digest(base_url))`
#        when `project_name` is nil/empty and `base_url` is non-empty,
#     4. a 32-character `String` matching `/\A[a-zA-Z0-9]{32}\z/`
#        when both are nil/empty.
#
# `prop_check` is not currently bundled in this package, so the
# property runs as a deterministic Minitest case backed by a seeded
# generator. The seed and iteration count are exposed as constants
# so a failing run can be reproduced byte-for-byte. The structure
# intentionally mirrors the other PBT files in this directory so
# swapping in `prop_check` later (gated by the conditional require
# in `test/test_helper.rb`) is mechanical.
#
# Each iteration:
#   - resets `BetterAuth::Telemetry.reset_project_id!` so the call
#     goes through the full derivation chain rather than reusing a
#     previous tuple's cached value;
#   - generates a `project_name` drawn from {`nil`, `""`, random
#     non-empty alphanumeric String} excluding the upstream
#     `"Better Auth"` sentinel (which the `from_app_name` resolver
#     intentionally treats as "not configured" — see
#     `ProjectId::DEFAULT_APP_NAME` and Requirement 14.7);
#   - generates a `base_url` drawn from {`nil`, `""`, random
#     non-empty URL-shaped String};
#   - injects the project name via
#     `BetterAuth::Telemetry::CurrentOptions.with_app_name(project_name)`
#     so the `from_app_name` rule resolves to the generated value;
#   - stubs `ProjectId.from_locked_gems` and
#     `ProjectId.from_bundler_root` to `nil` so the derivation chain
#     deterministically depends on the generated project_name (the
#     bundler probes are environment-dependent — pinning them to
#     `nil` is what makes the property reproducible);
#   - calls `BetterAuth::Telemetry.project_id(base_url)`;
#   - re-derives the expected return straight from the spec prose
#     so the assertion is meaningful and not just a round-trip
#     through the implementation.
#
# Validates: Requirements 14.1, 14.2, 14.3, 14.4, 14.5
module BetterAuth
  module Telemetry
    class ProjectIdDerivationPropertyTest < Minitest::Test
      Telemetry = BetterAuth::Telemetry
      CurrentOptions = BetterAuth::Telemetry::CurrentOptions
      ProjectId = BetterAuth::Telemetry::ProjectId

      # Total number of randomized iterations. The design floor is
      # 100; we run a comfortable margin over to soak the variation
      # across the 3 × 3 = 9 input quadrants (project_name and
      # base_url each in {nil, "", non-empty}).
      ITERATIONS = 150

      # Fixed seed so a counter-example can be reproduced verbatim
      # by rerunning the file. If you change the seed, write the new
      # seed into the test (do not rely on the global default).
      SEED = 0xC0FFEE_13

      # Alphabet for randomly generated `project_name` strings.
      # ASCII letters and digits keep the value JSON-safe and free
      # of byte sequences that might collide with the upstream
      # sentinel `"Better Auth"` (which contains a space).
      NAME_ALPHABET = (("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a).freeze

      # Schemes used when generating non-empty `base_url` strings.
      # Mixing http/https and a few host shapes ensures the test
      # exercises realistic byte-concatenation inputs to the
      # SHA-256 digest rather than a single canonical string.
      BASE_URL_SCHEMES = %w[https:// http://].freeze
      BASE_URL_HOSTS = %w[
        example.com
        acme.test
        localhost:3000
        api.example.io
        auth.local
        host-1.example.dev
      ].freeze

      # Per-axis input quadrants. `:nil` and `:empty` represent the
      # two "absent" forms; `:nonempty` triggers random generation
      # of a non-empty string. The two axes are sampled
      # independently so each iteration draws from a 3 × 3 grid of
      # `(project_name_axis, base_url_axis)` combinations.
      AXIS_VALUES = %i[nil empty nonempty].freeze

      # ---------------------------------------------------------------------
      # Property 13: project_id derivation rules.
      #
      # Validates: Requirements 14.1, 14.2, 14.3, 14.4, 14.5
      # ---------------------------------------------------------------------
      def test_property_13_project_id_derivation_rules
        rng = Random.new(SEED)

        # Deterministic boundary samples first. These pin every one
        # of the four documented derivation rules at least once so
        # a regression on a documented branch fails loudly before
        # random generation starts. Random iterations then sweep
        # the rest of the input space.
        deterministic_samples(rng).each_with_index do |sample, i|
          assert_property_13_holds(sample, label: "deterministic sample #{i}")
        end

        remaining = ITERATIONS - deterministic_samples(rng).length
        remaining = 0 if remaining.negative?
        remaining.times do |i|
          assert_property_13_holds(
            random_sample(rng),
            label: "random iteration #{i}"
          )
        end
      end

      private

      # Per-iteration tuple. `project_name` and `base_url` are the
      # post-generation values (each `nil`, `""`, or a non-empty
      # `String`); `name_axis` and `url_axis` record which input
      # axis was selected, purely for readable failure messages.
      Sample = Struct.new(
        :name_axis, :url_axis, :project_name, :base_url,
        keyword_init: true
      )

      # Fixed boundary samples that pin every documented rule at
      # least once, regardless of which random draws the seed
      # produces. The list is intentionally short — its purpose is
      # to fail loudly on a documented regression before the random
      # sweep starts. Random iterations do the heavy lifting.
      def deterministic_samples(rng)
        @deterministic_samples ||= [
          # Rule 1: both non-empty.
          Sample.new(
            name_axis: :nonempty,
            url_axis: :nonempty,
            project_name: random_project_name(rng),
            base_url: random_base_url(rng)
          ),
          # Rule 2 (a): name non-empty, base_url nil.
          Sample.new(
            name_axis: :nonempty,
            url_axis: :nil,
            project_name: random_project_name(rng),
            base_url: nil
          ),
          # Rule 2 (b): name non-empty, base_url empty.
          Sample.new(
            name_axis: :nonempty,
            url_axis: :empty,
            project_name: random_project_name(rng),
            base_url: ""
          ),
          # Rule 3 (a): name nil, base_url non-empty.
          Sample.new(
            name_axis: :nil,
            url_axis: :nonempty,
            project_name: nil,
            base_url: random_base_url(rng)
          ),
          # Rule 3 (b): name empty, base_url non-empty.
          Sample.new(
            name_axis: :empty,
            url_axis: :nonempty,
            project_name: "",
            base_url: random_base_url(rng)
          ),
          # Rule 4 (a): both nil.
          Sample.new(name_axis: :nil, url_axis: :nil, project_name: nil, base_url: nil),
          # Rule 4 (b): both empty.
          Sample.new(name_axis: :empty, url_axis: :empty, project_name: "", base_url: ""),
          # Rule 4 (c): name nil, base_url empty.
          Sample.new(name_axis: :nil, url_axis: :empty, project_name: nil, base_url: ""),
          # Rule 4 (d): name empty, base_url nil.
          Sample.new(name_axis: :empty, url_axis: :nil, project_name: "", base_url: nil)
        ].freeze
      end

      # Build a randomised `Sample`. Each axis is drawn
      # independently so every (name_axis, url_axis) pair from the
      # 3 × 3 grid is reachable.
      def random_sample(rng)
        name_axis = AXIS_VALUES.sample(random: rng)
        url_axis = AXIS_VALUES.sample(random: rng)

        Sample.new(
          name_axis: name_axis,
          url_axis: url_axis,
          project_name: project_name_for(name_axis, rng),
          base_url: base_url_for(url_axis, rng)
        )
      end

      # Materialise a `project_name` value for the given axis. The
      # `:nonempty` branch generates a random alphanumeric string
      # that is guaranteed not to equal the upstream sentinel
      # `"Better Auth"` (the alphabet excludes spaces, so the
      # generated value can never collide with the sentinel).
      def project_name_for(axis, rng)
        case axis
        when :nil then nil
        when :empty then ""
        when :nonempty then random_project_name(rng)
        end
      end

      # Materialise a `base_url` value for the given axis.
      def base_url_for(axis, rng)
        case axis
        when :nil then nil
        when :empty then ""
        when :nonempty then random_base_url(rng)
        end
      end

      # Random non-empty alphanumeric `String`. Lengths in 4..16
      # are large enough for SHA-256 input variation but small
      # enough that JSON encoding cost stays negligible. The
      # alphabet excludes whitespace so the value can never equal
      # the upstream sentinel `"Better Auth"`.
      def random_project_name(rng)
        length = 4 + rng.rand(13) # 4..16 inclusive
        Array.new(length) { NAME_ALPHABET.sample(random: rng) }.join
      end

      # Random non-empty URL-shaped `String`. The shape is purely
      # cosmetic — the property only cares that the string is
      # non-empty and feeds into the SHA-256 digest verbatim — but
      # using realistic-looking URLs keeps a counter-example
      # readable.
      def random_base_url(rng)
        scheme = BASE_URL_SCHEMES.sample(random: rng)
        host = BASE_URL_HOSTS.sample(random: rng)
        path = "/" + Array.new(1 + rng.rand(4)) { NAME_ALPHABET.sample(random: rng) }.join
        scheme + host + path
      end

      # Drive a single iteration of the property: reset the cache,
      # inject the generated project name via `with_app_name`, stub
      # the bundler probes to `nil`, call
      # `Telemetry.project_id(base_url)`, and assert the result
      # matches the spec-derived expectation.
      def assert_property_13_holds(sample, label:)
        Telemetry.reset_project_id!
        prior_app_name = CurrentOptions.app_name

        # Stub the bundler-backed probes to `nil` so the only
        # source the resolver can pick up is the
        # `from_app_name` rule. Without this pin the result would
        # depend on the host process's `Bundler.locked_gems` /
        # `Bundler.root`, which are not part of Property 13's
        # input axes.
        ProjectId.stub(:from_locked_gems, nil) do
          ProjectId.stub(:from_bundler_root, nil) do
            CurrentOptions.with_app_name(sample.project_name) do
              actual = Telemetry.project_id(sample.base_url)
              expected = expected_project_id(sample)

              assert_matches_expected(actual, expected, sample: sample, label: label)
            end
          end
        end
      ensure
        # Leave the cache and the thread-local app_name clean so a
        # later test that depends on a cold cache or unset app_name
        # is not affected by this iteration.
        Telemetry.reset_project_id!
        CurrentOptions.app_name = prior_app_name
      end

      # Re-derive the expected return value straight from the
      # Property 13 prose so the property does not just round-trip
      # through the implementation.
      #
      # Returns:
      #   - the exact `Base64(SHA-256(...))` string for rules 1-3, or
      #   - the symbol `:random_32` for rule 4, signaling that the
      #     observed value is non-deterministic and the assertion
      #     must check the documented `[a-zA-Z0-9]{32}` shape rather
      #     than a specific string.
      def expected_project_id(sample)
        name = sample.project_name
        url = sample.base_url

        name_present = name.is_a?(String) && !name.empty?
        url_present = url.is_a?(String) && !url.empty?

        if name_present && url_present
          base64_sha256(url + name)
        elsif name_present
          base64_sha256(name)
        elsif url_present
          base64_sha256(url)
        else
          :random_32
        end
      end

      # Assert the observed `actual` matches the expected derivation
      # for `sample`. Rule 4's expected value is a 32-char
      # `[a-zA-Z0-9]` shape rather than a specific string, so we
      # branch on the sentinel returned by `expected_project_id`.
      def assert_matches_expected(actual, expected, sample:, label:)
        message =
          "Telemetry.project_id violated Property 13 for #{label} " \
          "(name_axis=#{sample.name_axis.inspect}, url_axis=#{sample.url_axis.inspect}, " \
          "project_name=#{sample.project_name.inspect}, base_url=#{sample.base_url.inspect}): " \
          "got #{actual.inspect}"

        if expected == :random_32
          assert_kind_of String, actual, message + ", expected a 32-char [a-zA-Z0-9] String"
          assert_equal 32, actual.length, message + ", expected length 32"
          assert_match(/\A[a-zA-Z0-9]{32}\z/, actual, message + ", expected /\\A[a-zA-Z0-9]{32}\\z/")
        else
          assert_equal expected, actual, message + ", expected #{expected.inspect}"
        end
      end

      # Helper mirroring the implementation's
      # `Base64.strict_encode64(Digest::SHA256.digest(input))`. We
      # re-derive the value here rather than calling the
      # implementation's private `hash_to_base64` so the property
      # exercises an independent computation of the expected
      # output.
      def base64_sha256(input)
        Base64.strict_encode64(Digest::SHA256.digest(input))
      end
    end
  end
end
