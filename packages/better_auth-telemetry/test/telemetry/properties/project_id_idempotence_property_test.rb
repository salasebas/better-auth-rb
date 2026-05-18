# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/mock"
require "better_auth/telemetry/project_id"

# Property-based test for `BetterAuth::Telemetry.project_id`
# memoization / idempotence — Property 14 of `design.md`
# § Correctness Properties.
#
# Property 14 — project_id memoization / idempotence
#   *For any* sequence of calls
#   `project_id(b_1); project_id(b_2); …; project_id(b_n)`
#   after the first call returns a value `v_1`, every subsequent
#   call SHALL return a value `==` to `v_1`, regardless of the
#   value of `b_2 … b_n`.
#
# In other words: once the cache is hot, the argument no longer
# influences the return value. This is exactly the upstream
# `projectIdCached` semantics (Requirement 14.6) — derivation
# happens once per process, every later call is a cache hit. The
# property is a strict invariant: it holds for *any* mix of `nil`,
# `""`, and arbitrary non-empty URL strings, and for *any* project
# name configuration (`with_app_name` set or unset).
#
# `prop_check` is not currently bundled in this package, so the
# property runs as a deterministic Minitest case backed by a seeded
# `Random` generator. The seed and iteration count are exposed as
# constants so a failing run can be reproduced byte-for-byte. The
# structure intentionally mirrors the other PBT files in this
# directory (notably
# `project_id_derivation_property_test.rb`) so swapping in
# `prop_check` later (gated by the conditional require in
# `test/test_helper.rb`) is mechanical.
#
# Each iteration:
#   - resets `BetterAuth::Telemetry.reset_project_id!` so the first
#     call goes through the derivation chain (rather than reusing a
#     previous iteration's cached value);
#   - generates a sequence of 2–10 random `base_url` values, each
#     drawn from `{nil, "", random non-empty URL String}`;
#   - optionally injects a `project_name` via
#     `BetterAuth::Telemetry::CurrentOptions.with_app_name(...)`
#     (drawn from `{nil, "", "Better Auth", random non-empty
#     alphanumeric String}`) so the test sweeps both the "name
#     resolvable" and "no name resolvable" branches of the
#     derivation chain — Property 14 must hold in either case;
#   - stubs `ProjectId.from_locked_gems` and
#     `ProjectId.from_bundler_root` to `nil` so the host's actual
#     Bundler state can't bleed into the cached value (the property
#     is about idempotence, not derivation; pinning the probes
#     keeps `v_1` reproducible per seed);
#   - calls `BetterAuth::Telemetry.project_id(b_1)` to mint
#     `v_1`;
#   - calls `BetterAuth::Telemetry.project_id(b_i)` for each
#     subsequent `b_i` and asserts the result `==` `v_1`.
#
# The property does not assert anything about *which* derivation
# rule produced `v_1`; that is Property 13's job. Property 14 only
# cares that whatever the first call returned is what every later
# call returns, regardless of argument variation.
#
# Validates: Requirements 14.6, 20.6
module BetterAuth
  module Telemetry
    class ProjectIdIdempotencePropertyTest < Minitest::Test
      Telemetry = BetterAuth::Telemetry
      CurrentOptions = BetterAuth::Telemetry::CurrentOptions
      ProjectId = BetterAuth::Telemetry::ProjectId

      # Total number of randomized iterations. The design floor is
      # 100; we run a small margin over so the variation across
      # sequence lengths (2..10) and project-name shapes
      # ({nil, "", "Better Auth", non-empty}) gets a fair sweep.
      ITERATIONS = 150

      # Fixed seed so a counter-example can be reproduced verbatim
      # by rerunning the file. If you change the seed, write the new
      # seed into the test (do not rely on the global default).
      SEED = 0x1DE0_BAFF

      # Length bounds (inclusive) for the per-iteration sequence of
      # `base_url` calls. The lower bound of 2 guarantees at least
      # one *post-cache* call beyond `v_1` so the property has
      # something to verify.
      MIN_SEQUENCE_LENGTH = 2
      MAX_SEQUENCE_LENGTH = 10

      # Alphabet for randomly generated `project_name` strings.
      # ASCII letters and digits keep the value JSON-safe and free
      # of byte sequences that could collide with the upstream
      # sentinel `"Better Auth"` (the alphabet excludes whitespace).
      NAME_ALPHABET = (("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a).freeze

      # Schemes used when generating non-empty `base_url` strings.
      BASE_URL_SCHEMES = %w[https:// http://].freeze
      BASE_URL_HOSTS = %w[
        example.com
        acme.test
        localhost:3000
        api.example.io
        auth.local
        host-1.example.dev
      ].freeze

      # Per-call axes for `base_url`. `:nil` and `:empty` are the
      # two "absent" forms; `:nonempty` triggers random URL
      # generation. Every iteration draws each call's `base_url`
      # independently from this set so the post-cache calls vary
      # freely against the cached `v_1`.
      BASE_URL_AXES = %i[nil empty nonempty].freeze

      # Per-iteration project-name axes. The four cases jointly
      # cover both the "name resolvable" (Rules 1–2) and "no name
      # resolvable" (Rules 3–4) branches of the derivation chain:
      #   - `:unset`    – no `with_app_name` block at all,
      #   - `:nil`      – `with_app_name(nil)`,
      #   - `:empty`    – `with_app_name("")`,
      #   - `:default`  – `with_app_name("Better Auth")` (upstream
      #                   sentinel — `from_app_name` treats this as
      #                   "not configured", Requirement 14.7),
      #   - `:nonempty` – `with_app_name(<random alphanumeric>)`.
      NAME_AXES = %i[unset nil empty default nonempty].freeze

      # ---------------------------------------------------------------------
      # Property 14: project_id memoization / idempotence.
      #
      # Validates: Requirements 14.6, 20.6
      # ---------------------------------------------------------------------
      def test_property_14_project_id_memoization_is_idempotent
        rng = Random.new(SEED)

        ITERATIONS.times do |i|
          assert_property_14_holds(random_sample(rng), label: "iteration #{i}")
        end
      end

      private

      # Per-iteration tuple. `name_axis` records the project-name
      # branch under test (purely for readable failure messages);
      # `project_name_arg` is the value to pass to `with_app_name`
      # (only meaningful when `name_axis != :unset`); `base_urls`
      # is the generated 2..10-long sequence.
      Sample = Struct.new(:name_axis, :project_name_arg, :base_urls, keyword_init: true)

      # Build a randomised `Sample`. Each axis is drawn
      # independently so iterations can mix any name branch with
      # any sequence shape.
      def random_sample(rng)
        name_axis = NAME_AXES.sample(random: rng)
        project_name_arg = project_name_for(name_axis, rng)

        seq_length = MIN_SEQUENCE_LENGTH +
          rng.rand(MAX_SEQUENCE_LENGTH - MIN_SEQUENCE_LENGTH + 1)
        base_urls = Array.new(seq_length) { random_base_url(rng) }

        Sample.new(
          name_axis: name_axis,
          project_name_arg: project_name_arg,
          base_urls: base_urls
        )
      end

      # Materialise the `with_app_name` argument for the given axis.
      # Returns the special sentinel `:UNSET` for `:unset` so the
      # caller can skip the `with_app_name` block entirely (rather
      # than calling `with_app_name(nil)`, which is a *distinct*
      # branch — `:nil` — and exercises a different code path).
      def project_name_for(axis, rng)
        case axis
        when :unset then :UNSET
        when :nil then nil
        when :empty then ""
        when :default then ProjectId::DEFAULT_APP_NAME
        when :nonempty then random_project_name(rng)
        end
      end

      # Random non-empty alphanumeric `String`. Lengths in 4..16
      # are large enough to exercise SHA-256 input variation but
      # small enough that the test stays fast.
      def random_project_name(rng)
        length = 4 + rng.rand(13) # 4..16 inclusive
        Array.new(length) { NAME_ALPHABET.sample(random: rng) }.join
      end

      # Per-call `base_url` value drawn uniformly from the three
      # axes. Returning a fresh value per call (rather than reusing
      # a single value across the sequence) is what makes the
      # property meaningful: a memoization that reused the
      # *argument* of the first call rather than the *result* of
      # the first call would still pass a "same input every time"
      # test but fail this one.
      def random_base_url(rng)
        case BASE_URL_AXES.sample(random: rng)
        when :nil then nil
        when :empty then ""
        when :nonempty then build_random_url(rng)
        end
      end

      # Random non-empty URL-shaped `String`. The shape is purely
      # cosmetic — Property 14 only cares that the value has no
      # influence on post-cache return values — but realistic-
      # looking URLs keep counter-examples readable.
      def build_random_url(rng)
        scheme = BASE_URL_SCHEMES.sample(random: rng)
        host = BASE_URL_HOSTS.sample(random: rng)
        path = "/" + Array.new(1 + rng.rand(4)) { NAME_ALPHABET.sample(random: rng) }.join
        scheme + host + path
      end

      # Drive a single iteration of the property: reset the cache,
      # optionally enter a `with_app_name` scope, stub the bundler
      # probes to `nil`, mint `v_1` from the first `base_url`, and
      # assert every subsequent call returns `==` to `v_1`.
      def assert_property_14_holds(sample, label:)
        Telemetry.reset_project_id!
        prior_app_name = CurrentOptions.app_name

        # Stub the bundler-backed probes to `nil` so the host's
        # actual Bundler state can't bleed into the cached value.
        # The property is about idempotence, not derivation;
        # pinning the probes keeps `v_1` reproducible per seed and
        # lets a failure point at the cache rather than at a flaky
        # environment probe.
        ProjectId.stub(:from_locked_gems, nil) do
          ProjectId.stub(:from_bundler_root, nil) do
            run_sequence_under_app_name(sample, label)
          end
        end
      ensure
        # Leave the cache and the thread-local app_name clean so a
        # later test that depends on a cold cache or unset app_name
        # is not affected by this iteration.
        Telemetry.reset_project_id!
        CurrentOptions.app_name = prior_app_name
      end

      # Run the per-iteration call sequence either inside a
      # `with_app_name` scope (when an app name is configured) or
      # directly (when the axis is `:unset`). Splitting this out
      # keeps the two branches explicit rather than threading a
      # conditional through `with_app_name`.
      def run_sequence_under_app_name(sample, label)
        if sample.name_axis == :unset
          assert_sequence_idempotent(sample, label: label)
        else
          CurrentOptions.with_app_name(sample.project_name_arg) do
            assert_sequence_idempotent(sample, label: label)
          end
        end
      end

      # Core property assertion: every derivation input is idempotent
      # for repeated calls. Different base URLs may intentionally
      # produce different ids; the cache is keyed by derivation input.
      def assert_sequence_idempotent(sample, label:)
        sample.base_urls.each_with_index do |b_i, i|
          first = Telemetry.project_id(b_i)
          second = Telemetry.project_id(b_i)

          assert_kind_of String, first,
            "Telemetry.project_id returned a non-String for #{label} " \
            "(name_axis=#{sample.name_axis.inspect}, " \
            "project_name_arg=#{sample.project_name_arg.inspect}, " \
            "call #{i} base_url=#{b_i.inspect}): got #{first.inspect}"
          refute_empty first,
            "Telemetry.project_id returned an empty String for #{label} " \
            "(name_axis=#{sample.name_axis.inspect}, " \
            "call #{i} base_url=#{b_i.inspect})"

          assert_equal first, second,
            "Telemetry.project_id violated Property 14 for #{label} " \
            "(name_axis=#{sample.name_axis.inspect}, " \
            "project_name_arg=#{sample.project_name_arg.inspect}, " \
            "call #{i} base_url=#{b_i.inspect}): " \
            "expected #{first.inspect}, got #{second.inspect}"
        end
      end
    end
  end
end
