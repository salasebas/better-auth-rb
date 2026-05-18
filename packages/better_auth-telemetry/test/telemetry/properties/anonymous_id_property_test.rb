# frozen_string_literal: true

require_relative "../../test_helper"
require "better_auth/telemetry"
require_relative "../support/env_helpers"
require_relative "../support/recording_track"

# Property-based tests for `anonymousId` reuse across the lifetime of
# a single opted-in `BetterAuth::Telemetry::Publisher` (see
# `lib/better_auth/telemetry/publisher.rb` and the publisher returned
# from `lib/better_auth/telemetry/create.rb`).
#
# The invariant — Property 6 of `design.md` § Correctness Properties —
# states:
#
#   For any sequence of `#publish(event)` calls on a single opted-in
#   `Publisher` `P` created with `base_url = U`, every emitted event's
#   `anonymousId` SHALL equal `BetterAuth::Telemetry.project_id(U)`
#   evaluated at create time, and SHALL be the same string across all
#   events emitted by `P`.
#
# Concretely the property splits into three checks against the events
# captured by a `RecordingTrack` injected as `custom_track`:
#
#   1. Every recorded event (the create-time init event plus the 1–5
#      events emitted by `publisher.publish(...)`) carries an
#      `anonymousId` that is a non-empty `String`.
#   2. All recorded events share the *same* `anonymousId` string —
#      i.e. the publisher reuses the id that was minted for the init
#      event rather than re-resolving on every call.
#   3. The shared `anonymousId` matches `BetterAuth::Telemetry.project_id(U)`
#      as evaluated under the same `with_app_name` scope used at
#      create time (the alignment half of Property 6). Because
#      `project_id` is memoized for the life of the cache, calling it
#      again without resetting the cache returns the same value that
#      `Telemetry.create` used when minting the init event, which is
#      exactly what the property requires.
#
# `prop_check` is not currently bundled in this package, so the
# property runs as a deterministic Minitest case backed by a seeded
# generator. The structure is intentionally close to a `prop_check`
# property so that swapping in `prop_check` later (gated by the
# conditional require in `test/test_helper.rb`) is mechanical: each
# iteration runs the same universal assertion against one generated
# `(base_url, app_name, publish_event_sequence)` tuple.
#
# Per design (`design.md` § Correctness Properties), the property
# runs ≥100 iterations. The iteration count and seed are exposed as
# constants so a failing run can be reproduced byte-for-byte.
#
# Validates: Requirements 6.2, 6.10
module BetterAuth
  module Telemetry
    class AnonymousIdPropertyTest < Minitest::Test
      include BetterAuth::Telemetry::Test::EnvHelpers

      Telemetry = BetterAuth::Telemetry
      Publisher = BetterAuth::Telemetry::Publisher
      RecordingTrack = BetterAuth::Telemetry::Test::RecordingTrack

      # Total number of randomized iterations. The design floor is
      # 100; we run a few extra to soak across the small input axes
      # (base_url, app_name, publish-event sequence length).
      ITERATIONS = 120

      # Fixed seed so a counter-example can be reproduced verbatim by
      # rerunning the file. If you change the seed, write the new seed
      # into the test (do not rely on the global default).
      SEED = 0xA011_DEED

      # Sample app names. Includes `nil` so the project-name resolver
      # falls through to the Bundler-derived rules (or the random
      # fallback when Bundler signals nothing useful), and the
      # upstream sentinel `"Better Auth"` which the resolver
      # intentionally treats as "not configured" so the same fallthrough
      # path is exercised even when an app_name is set.
      APP_NAMES = [
        nil,
        "Better Auth",
        "AcmeApp",
        "test-host",
        "PropertyHarness",
        "rb-telemetry-spec"
      ].freeze

      # Sample base URLs. A `nil` base_url is also a valid input — it
      # falls through to one of the project_id derivation rules — so
      # the generator includes it.
      BASE_URLS = [
        nil,
        "",
        "https://example.com",
        "https://acme.test",
        "http://localhost:3000",
        "https://api.example.io/auth"
      ].freeze

      # Sample event types used when calling `publisher.publish(...)`.
      # The publisher's behaviour is event-shape-agnostic — Property 6
      # is purely about `anonymousId` — so a small fixed set of
      # plausible-looking type strings is sufficient.
      EVENT_TYPES = %w[
        ping
        signup.success
        signin.success
        password.reset
        session.created
        session.revoked
        plugin.invoked
        custom-event
      ].freeze

      # ---------------------------------------------------------------------
      # Property 6: anonymousId reuse and project_id alignment.
      #
      # For every randomly-generated `(base_url, app_name, publish
      # sequence)` tuple drawn from a fixed seed:
      #
      #   1. Each recorded event's `anonymousId` is a non-empty `String`.
      #   2. Every recorded event shares the same `anonymousId` string.
      #   3. That shared id matches `BetterAuth::Telemetry.project_id(base_url)`
      #      as evaluated under the same `with_app_name` scope used at
      #      create time, confirming alignment with the project_id
      #      resolution chain.
      #
      # Validates: Requirements 6.2, 6.10
      # ---------------------------------------------------------------------
      def test_property_6_anonymous_id_reuse_and_alignment
        rng = Random.new(SEED)

        ITERATIONS.times do |i|
          assert_anonymous_id_property_holds(rng: rng, iteration: i)
        end
      end

      private

      # Drive a single iteration of the property: build a random
      # `(base_url, app_name, publish-event sequence)` tuple, opt the
      # process in via env, run `Telemetry.create`, fire the planned
      # publish sequence, and assert all three invariants on the
      # recorded events.
      def assert_anonymous_id_property_holds(rng:, iteration:)
        # The project_id memo is process-global; clear it before the
        # iteration so the create call goes through the full
        # derivation chain under this iteration's `(base_url,
        # app_name)` inputs rather than reusing a previous tuple's
        # cached value.
        Telemetry.reset_project_id!

        base_url = BASE_URLS.sample(random: rng)
        app_name = APP_NAMES.sample(random: rng)
        publish_count = 1 + rng.rand(5) # 1..5
        events_to_publish = Array.new(publish_count) { generate_publish_event(rng) }

        recorder = RecordingTrack.new
        options = {
          telemetry: {enabled: true},
          app_name: app_name,
          base_url: base_url
        }
        context = {
          custom_track: recorder,
          # `skip_test_check: true` so an inherited `RAILS_ENV=test`
          # from the parent process never silently disables telemetry
          # mid-property. The `with_env` block pins the test markers
          # to nil for completeness, but pinning skip_test_check
          # makes the property robust under any harness.
          skip_test_check: true
        }

        with_env(opt_in_env_overrides) do
          publisher = Telemetry.create(options, context)

          assert_kind_of(
            Publisher,
            publisher,
            label_for(iteration: iteration, base_url: base_url, app_name: app_name) +
              ": expected an enabled Publisher"
          )
          assert_predicate(
            publisher,
            :enabled?,
            label_for(iteration: iteration, base_url: base_url, app_name: app_name) +
              ": expected publisher.enabled? to be true"
          )

          events_to_publish.each { |event| publisher.publish(event) }

          # Recompute the expected id under the same `with_app_name`
          # scope used at create time. Because `project_id` is
          # memoized and the cache was filled by `Telemetry.create`,
          # this returns the exact value used to mint the init event
          # — which is precisely what Property 6 requires
          # ("evaluated at create time").
          expected_id = CurrentOptions.with_app_name(app_name) do
            Telemetry.project_id(base_url)
          end

          recorded = recorder.events
          # Init event + N publish events. We did not opt for the
          # debug or HTTP delivery paths so every emitted event must
          # land in the recorder.
          assert_equal(
            1 + publish_count,
            recorded.size,
            label_for(iteration: iteration, base_url: base_url, app_name: app_name) +
              ": expected #{1 + publish_count} recorded events (1 init + #{publish_count} publish), got #{recorded.size}"
          )

          assert_invariant_1_anonymous_ids_are_non_empty_strings(
            recorded,
            iteration: iteration, base_url: base_url, app_name: app_name
          )
          assert_invariant_2_anonymous_ids_are_uniform(
            recorded,
            iteration: iteration, base_url: base_url, app_name: app_name
          )
          assert_invariant_3_anonymous_id_aligns_with_project_id(
            recorded, expected_id,
            iteration: iteration, base_url: base_url, app_name: app_name
          )
        end
      ensure
        # Leave the cache clean for any later test that depends on a
        # cold project_id memo.
        Telemetry.reset_project_id!
      end

      # Invariant 1: every recorded event carries a non-empty String
      # `anonymousId`. The publisher should never emit an event with a
      # `nil` or blank id.
      def assert_invariant_1_anonymous_ids_are_non_empty_strings(events, iteration:, base_url:, app_name:)
        events.each_with_index do |event, idx|
          assert_kind_of(
            Hash,
            event,
            label_for(iteration: iteration, base_url: base_url, app_name: app_name) +
              ": event #{idx} must be a Hash"
          )
          anon = event[:anonymousId]
          assert_kind_of(
            String,
            anon,
            label_for(iteration: iteration, base_url: base_url, app_name: app_name) +
              ": event #{idx}[:anonymousId] must be a String, got #{anon.class}"
          )
          refute_predicate(
            anon,
            :empty?,
            label_for(iteration: iteration, base_url: base_url, app_name: app_name) +
              ": event #{idx}[:anonymousId] must be non-empty"
          )
        end
      end

      # Invariant 2: every recorded event shares the same
      # `anonymousId` string. This is the heart of Property 6 — the
      # publisher must reuse the id minted at create time rather than
      # re-resolving on each `#publish` call.
      def assert_invariant_2_anonymous_ids_are_uniform(events, iteration:, base_url:, app_name:)
        ids = events.map { |e| e[:anonymousId] }
        unique = ids.uniq
        assert_equal(
          1,
          unique.size,
          label_for(iteration: iteration, base_url: base_url, app_name: app_name) +
            ": expected all events to share one anonymousId, got #{unique.size} distinct values: #{unique.inspect}"
        )
      end

      # Invariant 3: the shared `anonymousId` aligns with
      # `BetterAuth::Telemetry.project_id(base_url)` evaluated at
      # create time (here: re-evaluated post-create against the still-
      # warm memo, under the same `with_app_name` scope).
      def assert_invariant_3_anonymous_id_aligns_with_project_id(events, expected_id, iteration:, base_url:, app_name:)
        observed = events.first[:anonymousId]
        assert_equal(
          expected_id,
          observed,
          label_for(iteration: iteration, base_url: base_url, app_name: app_name) +
            ": expected anonymousId to equal Telemetry.project_id(base_url), got #{observed.inspect} vs #{expected_id.inspect}"
        )
      end

      # Baseline ENV overrides that opt the process in via
      # `BETTER_AUTH_TELEMETRY=1`, clear the test-environment markers
      # so the in-test gate does not reject the opt-in, and pin the
      # `OPEN_AUTH_*` aliases / debug / endpoint env vars to known
      # values so the outer process environment cannot leak in. We
      # rely on the iteration's `custom_track` recorder for delivery,
      # so the endpoint stays unset.
      def opt_in_env_overrides
        {
          "BETTER_AUTH_TELEMETRY" => "1",
          "OPEN_AUTH_TELEMETRY" => nil,
          "BETTER_AUTH_TELEMETRY_DEBUG" => nil,
          "OPEN_AUTH_TELEMETRY_DEBUG" => nil,
          "BETTER_AUTH_TELEMETRY_ENDPOINT" => nil,
          "OPEN_AUTH_TELEMETRY_ENDPOINT" => nil,
          "RACK_ENV" => nil,
          "RAILS_ENV" => nil,
          "APP_ENV" => nil
        }
      end

      # Build a small, plausible-looking event hash for
      # `publisher.publish(...)`. The publisher's behaviour under
      # Property 6 is independent of the event payload, so a tiny
      # generator is sufficient — we mainly want event-to-event
      # variation so the test does not accidentally pass for a single
      # repeated event shape.
      def generate_publish_event(rng)
        {
          type: EVENT_TYPES.sample(random: rng),
          payload: {
            iter: rng.rand(1_000_000),
            tag: %w[a b c d e].sample(random: rng)
          }
        }
      end

      def label_for(iteration:, base_url:, app_name:)
        "iteration #{iteration} (base_url=#{base_url.inspect}, app_name=#{app_name.inspect})"
      end
    end
  end
end
