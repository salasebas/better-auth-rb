# frozen_string_literal: true

require "json"

require_relative "../../test_helper"
require "better_auth"
require "better_auth/telemetry"

require_relative "../support/env_helpers"

# Property-based test for the publisher's exception-safety invariant —
# Property 16 of `design.md` § Correctness Properties.
#
# Property 16 — `auth.telemetry.publish` is exception-safe
#
#   For any `BetterAuth::Auth` instance constructed with any combination of
#     - `better_auth-telemetry` gem present or absent,
#     - telemetry opted in or opted out,
#     - `custom_track` raising or not raising,
#     - HTTP endpoint reachable or unreachable,
#   calling
#     `auth.telemetry.publish({type: <string>, payload: <JSON-encodable hash>})`
#   SHALL return without raising any `StandardError`.
#
# This property pins down the four nested rescue boundaries documented
# in `design.md` § Error Handling:
#
#   - `BetterAuth::Auth#build_telemetry_publisher` rescues `LoadError`
#     and `StandardError` so missing-gem and creation failures degrade
#     to a noop publisher rather than aborting `Auth#initialize`.
#   - The track lambda built by `BetterAuth::Telemetry.create` wraps
#     every `custom_track` / debug-logger / HTTP dispatch in a
#     `rescue StandardError` and routes the failure through the
#     configured logger.
#   - `Publisher#publish` carries an outer `rescue StandardError` so a
#     misbehaving track callable cannot escalate either.
#   - `NoopPublisher#publish` is unconditionally `nil`-returning.
#
# Property 16 says: regardless of which boundary actually fires (or
# whether none fires at all), `publish` is total — every call returns
# without raising a `StandardError`.
#
# `prop_check` is not currently bundled in this package, so the
# property runs as a deterministic Minitest case backed by a seeded
# generator. The structure is intentionally close to a `prop_check`
# property so that swapping in `prop_check` later (gated by the
# conditional require in `test/test_helper.rb`) is mechanical: each
# iteration runs the same universal assertion against one generated
# `(gem_present, opted_in, custom_track_kind, http_kind, event)` tuple.
#
# Per design (`design.md` § Correctness Properties), the property
# runs ≥100 iterations. The iteration count and seed are exposed as
# constants so a failing run can be reproduced byte-for-byte.
#
# Conditions varied per iteration:
#
#   - **gem_present** ∈ {true, false} — the gem-absent half is
#     simulated by a `BetterAuth::Auth` subclass that overrides
#     `build_telemetry_publisher` to raise `LoadError` (matches the
#     `auth_soft_load_test.rb` approach). The gem-present half drives
#     the real `BetterAuth::Telemetry.create` pipeline.
#   - **opted_in** ∈ {true, false} — driven by `BETTER_AUTH_TELEMETRY`.
#     `Configuration` does not expose a telemetry slot, so the env var
#     is the sole opt-in lever at the `Auth` boundary.
#   - **custom_track_kind** ∈ {:none, :ok, :raising} — `:ok` injects a
#     no-op `Proc`, `:raising` injects a `Proc` that always raises
#     `StandardError`, `:none` leaves `custom_track` unset and lets the
#     publisher fall through to the HTTP / noop branches.
#   - **http_kind** ∈ {:none, :unreachable} — sets
#     `BETTER_AUTH_TELEMETRY_ENDPOINT` to either nothing (forces the
#     no-delivery short-circuit when `custom_track` is also absent) or
#     `http://127.0.0.1:1` (a closed port that exercises the HTTP rescue
#     boundary without depending on a live server).
#
# Validates: Requirements 5.6, 5.7, 16.6, 21.3
module BetterAuth
  module Telemetry
    class PublishExceptionSafetyPropertyTest < Minitest::Test
      include BetterAuth::Telemetry::Test::EnvHelpers

      Telemetry = BetterAuth::Telemetry

      # Total number of randomized iterations. The design floor is
      # 100; we layer the deterministic 24-cell sweep below that
      # floor and then add randomized iterations to soak across the
      # event-shape axis.
      RANDOM_ITERATIONS = 100

      # Fixed seed so a counter-example can be reproduced verbatim
      # by rerunning the file. If you change the seed, write the
      # new seed into the test (do not rely on the global default).
      SEED = 0x5AFE_E0E5

      # ---------------------------------------------------------------------
      # Test fixtures: secret/base_url known to satisfy
      # `Configuration#validate_secret`. The secret is long enough to
      # avoid the entropy/length warnings printed to stderr by the
      # configuration validator.
      # ---------------------------------------------------------------------
      SECRET = "test-secret-that-is-long-enough-for-validation"
      BASE_URL = "http://localhost:3000"

      # Closed-port URL used to exercise the HTTP-rescue boundary
      # without depending on a live server. Port 1 on the loopback
      # interface is reserved (TCPMUX) and is reliably refused on
      # CI hosts; the rescue inside `HttpClient.post_json` and the
      # outer rescue in the track lambda must absorb the
      # `Errno::ECONNREFUSED` (or equivalent) without raising.
      UNREACHABLE_ENDPOINT = "http://127.0.0.1:1/telemetry"

      # Domains for the random tuple axes. Kept as constants so the
      # exhaustive sweep below and the randomized sweep both draw
      # from the exact same input space.
      GEM_PRESENT_DOMAIN = [true, false].freeze
      OPTED_IN_DOMAIN = [true, false].freeze
      CUSTOM_TRACK_DOMAIN = %i[none ok raising].freeze
      HTTP_DOMAIN = %i[none unreachable].freeze

      # Alphabet for generated event-type / hash-key strings.
      STRING_ALPHABET = (("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a).freeze

      # Bounded payload generator parameters. Kept tight so each
      # iteration runs in roughly constant time while still exposing
      # the publisher to nested hashes / arrays / mixed scalars.
      MAX_PAYLOAD_DEPTH = 3
      MAX_HASH_KEYS = 3
      MAX_ARRAY_ENTRIES = 3
      INTEGER_BOUND = 1_000_000

      # ---------------------------------------------------------------------
      # `BetterAuth::Auth` subclass used to drive the property.
      #
      # Overrides the private `telemetry_context` so each iteration
      # can inject the chosen `custom_track` callable and bypass the
      # in-test gate (`skip_test_check: true`) without monkey-patching
      # the inherited method on every iteration. Stores the chosen
      # `custom_track_kind` on the instance so `telemetry_context`
      # picks the right callable shape.
      # ---------------------------------------------------------------------
      class HarnessAuth < ::BetterAuth::Auth
        # Supported track kinds matching {CUSTOM_TRACK_DOMAIN}.
        OK_TRACK = ->(_event) {}
        RAISING_TRACK = ->(_event) { raise StandardError, "harness custom_track raises" }

        attr_accessor :_custom_track_kind

        private

        def telemetry_context
          base = super.merge(skip_test_check: true)
          case @_custom_track_kind
          when :ok then base.merge(custom_track: OK_TRACK)
          when :raising then base.merge(custom_track: RAISING_TRACK)
          else base
          end
        end
      end

      # ---------------------------------------------------------------------
      # `BetterAuth::Auth` subclass used to drive the gem-absent half
      # of the property. Forces the `LoadError` branch of the
      # inherited `build_telemetry_publisher` so the publisher comes
      # from the noop fallback rather than `Telemetry.create`.
      # ---------------------------------------------------------------------
      class GemAbsentHarnessAuth < HarnessAuth
        private

        def build_telemetry_publisher
          raise LoadError, "simulated: better_auth/telemetry not loadable"
        rescue LoadError
          noop_telemetry_publisher
        end
      end

      def setup
        Telemetry.reset_project_id!
      end

      def teardown
        Telemetry.reset_project_id!
      end

      # ---------------------------------------------------------------------
      # Property 16: `auth.telemetry.publish` is exception-safe.
      #
      # For every randomly-generated `(gem_present, opted_in,
      # custom_track_kind, http_kind, event)` tuple drawn from a
      # fixed seed:
      #
      #   1. `BetterAuth::Auth.new(...)` succeeds without raising
      #      (Requirement 16.5 — telemetry creation never breaks
      #      core initialization).
      #   2. `auth.telemetry.publish(event)` returns without raising
      #      a `StandardError` (the property body — Requirements
      #      5.6, 5.7, 16.6, 21.3).
      #   3. The return value is `nil`. The `Publisher`,
      #      `NoopPublisher`, and `Auth#noop_telemetry_publisher`
      #      contracts all return `nil`, so this is a tighter check
      #      than the property strictly requires; we only flunk
      #      when a non-`nil` value comes back together with no
      #      raise (which would still be a contract drift worth
      #      catching).
      #
      # Validates: Requirements 5.6, 5.7, 16.6, 21.3
      # ---------------------------------------------------------------------
      def test_property_16_publish_is_exception_safe
        rng = Random.new(SEED)

        # 1. Exhaustive sweep across the four discrete axes (24
        #    cells). The event payload is still drawn at random per
        #    cell so we don't pin the publish-side input to a
        #    single shape.
        GEM_PRESENT_DOMAIN.each do |gem_present|
          OPTED_IN_DOMAIN.each do |opted_in|
            CUSTOM_TRACK_DOMAIN.each do |custom_track_kind|
              HTTP_DOMAIN.each do |http_kind|
                assert_publish_exception_safe(
                  rng: rng,
                  gem_present: gem_present,
                  opted_in: opted_in,
                  custom_track_kind: custom_track_kind,
                  http_kind: http_kind,
                  event: generate_event(rng)
                )
              end
            end
          end
        end

        # 2. Randomized iterations on top of the deterministic
        #    sweep. The same axes are sampled uniformly so the
        #    property gets re-checked with fresh event payloads
        #    rather than only the deterministic corners.
        RANDOM_ITERATIONS.times do
          assert_publish_exception_safe(
            rng: rng,
            gem_present: GEM_PRESENT_DOMAIN.sample(random: rng),
            opted_in: OPTED_IN_DOMAIN.sample(random: rng),
            custom_track_kind: CUSTOM_TRACK_DOMAIN.sample(random: rng),
            http_kind: HTTP_DOMAIN.sample(random: rng),
            event: generate_event(rng)
          )
        end
      end

      private

      # Drive a single iteration of the property: build the env
      # overrides, instantiate the appropriate `Auth` subclass with
      # the chosen `custom_track_kind`, call `publish`, and assert
      # the call returns `nil` without raising.
      def assert_publish_exception_safe(rng:, gem_present:, opted_in:, custom_track_kind:, http_kind:, event:)
        # The project_id memo is process-global; reset it between
        # iterations so the create call goes through the full
        # derivation chain rather than reusing a previous tuple's
        # cached value.
        Telemetry.reset_project_id!

        overrides = env_overrides(opted_in: opted_in, http_kind: http_kind)
        klass = gem_present ? HarnessAuth : GemAbsentHarnessAuth
        label = format_label(
          gem_present: gem_present,
          opted_in: opted_in,
          custom_track_kind: custom_track_kind,
          http_kind: http_kind,
          event: event
        )

        with_env(overrides) do
          auth = nil
          begin
            auth = klass.new(secret: SECRET, base_url: BASE_URL, database: :memory)
          rescue => e
            flunk("#{label}: Auth.new raised #{e.class}: #{e.message}")
          end
          auth._custom_track_kind = custom_track_kind

          # The publisher returned from `auth.telemetry` is one of:
          #   - a real `BetterAuth::Telemetry::Publisher` (gem
          #     present + opted in + delivery channel available),
          #   - a `BetterAuth::Telemetry::NoopPublisher` (gem
          #     present, opted out or no delivery channel), or
          #   - the anonymous noop publisher built by
          #     `Auth#noop_telemetry_publisher` (gem absent).
          # Property 16 only constrains `publish`, not the publisher
          # type — the type assertion is intentionally loose so a
          # later refactor that swaps the noop carrier doesn't
          # invalidate the property.
          refute_nil(auth.telemetry, "#{label}: auth.telemetry must not be nil")
          assert_respond_to(auth.telemetry, :publish, "#{label}: auth.telemetry must respond to #publish")

          result = nil
          begin
            result = auth.telemetry.publish(event)
          rescue => e
            flunk("#{label}: publish raised #{e.class}: #{e.message}")
          end

          assert_nil(result, "#{label}: publish must return nil; got #{result.inspect}")
        end
      ensure
        Telemetry.reset_project_id!
      end

      # Build the ENV override hash. We pin every variable that
      # influences the publish path so the outer process
      # environment can never leak in and skew the iteration's
      # opt-in / debug / endpoint / test-env signal:
      #
      #   - `BETTER_AUTH_TELEMETRY` toggles opt-in.
      #   - `OPEN_AUTH_TELEMETRY` is held to `nil` to avoid the
      #     alias prefix re-opting the process in when we want
      #     opted-out.
      #   - `BETTER_AUTH_TELEMETRY_ENDPOINT` selects the HTTP
      #     branch (set to the unreachable URL) or the
      #     no-delivery short-circuit (cleared).
      #   - `BETTER_AUTH_TELEMETRY_DEBUG` is held off so the debug
      #     branch never silently absorbs the test.
      #   - `RACK_ENV/RAILS_ENV/APP_ENV` are cleared so the in-test
      #     gate cannot disable telemetry mid-property; the
      #     harness also passes `skip_test_check: true` for
      #     redundancy.
      #   - `BASE_URL` / `BETTER_AUTH_URL` are cleared so the
      #     `Configuration#normalize_base_url` resolution uses the
      #     explicit `base_url:` argument.
      def env_overrides(opted_in:, http_kind:)
        {
          "BETTER_AUTH_TELEMETRY" => opted_in ? "1" : nil,
          "OPEN_AUTH_TELEMETRY" => nil,
          "BETTER_AUTH_TELEMETRY_ENDPOINT" => (http_kind == :unreachable) ? UNREACHABLE_ENDPOINT : nil,
          "OPEN_AUTH_TELEMETRY_ENDPOINT" => nil,
          "BETTER_AUTH_TELEMETRY_DEBUG" => nil,
          "OPEN_AUTH_TELEMETRY_DEBUG" => nil,
          "RACK_ENV" => nil,
          "RAILS_ENV" => nil,
          "APP_ENV" => nil,
          "BASE_URL" => nil,
          "BETTER_AUTH_URL" => nil
        }
      end

      # Build a small JSON-encodable event for `publish`. The
      # publisher accepts both symbol and string keys at the top
      # level; we randomize between the two so the symbol/string
      # normalization branch in `Publisher#publish` is exercised
      # alongside the property.
      def generate_event(rng)
        type = generate_string(rng)
        payload = generate_hash(rng, depth: 0)
        if rng.rand < 0.5
          {type: type, payload: payload}
        else
          {"type" => type, "payload" => payload}
        end
      end

      def generate_string(rng)
        length = 1 + rng.rand(12)
        Array.new(length) { STRING_ALPHABET.sample(random: rng) }.join
      end

      def generate_integer(rng)
        rng.rand(-INTEGER_BOUND..INTEGER_BOUND)
      end

      def generate_scalar(rng)
        case rng.rand(5)
        when 0 then generate_integer(rng)
        when 1 then generate_string(rng)
        when 2 then true
        when 3 then false
        end
      end

      def generate_value(rng, depth:)
        return generate_scalar(rng) if depth >= MAX_PAYLOAD_DEPTH

        case rng.rand(10)
        when 0..6 then generate_scalar(rng)
        when 7..8 then generate_hash(rng, depth: depth + 1)
        else generate_array(rng, depth: depth + 1)
        end
      end

      def generate_hash(rng, depth:)
        key_count = rng.rand(MAX_HASH_KEYS + 1)
        used = {}
        result = {}

        key_count.times do
          base = generate_string(rng)
          key = (rng.rand < 0.5) ? base.to_sym : base

          normalized_key = key.is_a?(Symbol) ? key.to_s : key
          next if used.key?(normalized_key)
          used[normalized_key] = true

          result[key] = generate_value(rng, depth: depth)
        end

        result
      end

      def generate_array(rng, depth:)
        length = rng.rand(MAX_ARRAY_ENTRIES + 1)
        Array.new(length) { generate_value(rng, depth: depth) }
      end

      def format_label(gem_present:, opted_in:, custom_track_kind:, http_kind:, event:)
        "gem_present=#{gem_present} " \
          "opted_in=#{opted_in} " \
          "custom_track_kind=#{custom_track_kind} " \
          "http_kind=#{http_kind} " \
          "event=#{event.inspect}"
      end
    end
  end
end
