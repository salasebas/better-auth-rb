# frozen_string_literal: true

require_relative "../../test_helper"
require "better_auth/telemetry"
require_relative "../support/env_helpers"
require_relative "../support/recording_track"

# Property-based tests for the init-event top-level shape invariant
# emitted by `BetterAuth::Telemetry.create` (see
# `lib/better_auth/telemetry/create.rb`, `compose_init_event`).
#
# The invariant — Property 4 of `design.md` § Correctness Properties —
# states that for any opted-in valid options hash and context, the
# emitted init event SHALL have:
#
#   1. `event[:type] == "init"`,
#   2. `event[:anonymousId]` is a non-empty `String`,
#   3. `event[:payload].keys` is exactly the set
#      `{:config, :runtime, :database, :framework, :environment,
#        :systemInfo, :packageManager}` (camelCase preserved as Ruby
#      symbol keys),
#   4. `event[:payload][:config].keys` is a superset of the upstream
#      `getTelemetryAuthConfig` top-level key set
#      `{database, adapter, emailVerification, emailAndPassword,
#        socialProviders, plugins, user, verification, session,
#        account, hooks, secondaryStorage, advanced, trustedOrigins,
#        rateLimit, onAPIError, logger, databaseHooks}`.
#
# `prop_check` is not currently bundled in this package, so the
# property runs as a deterministic Minitest case backed by a seeded
# generator. The structure is intentionally close to a `prop_check`
# property so that swapping in `prop_check` later (gated by the
# conditional require in `test/test_helper.rb`) is mechanical: each
# iteration runs the same universal assertion against one generated
# `(options, context)` tuple.
#
# Per design (`design.md` § Correctness Properties), the property
# runs ≥100 iterations. The iteration count and seed are exposed as
# constants so a failing run can be reproduced byte-for-byte.
#
# Validates: Requirements 6.1, 6.3, 6.4, 13.2
module BetterAuth
  module Telemetry
    class InitEventShapePropertyTest < Minitest::Test
      include BetterAuth::Telemetry::Test::EnvHelpers

      Telemetry = BetterAuth::Telemetry
      Publisher = BetterAuth::Telemetry::Publisher
      RecordingTrack = BetterAuth::Telemetry::Test::RecordingTrack

      # Total number of randomized iterations. The design floor is
      # 100; we run a few extra to soak the variation across the
      # generator's option-section permutations.
      ITERATIONS = 120

      # Fixed seed so a counter-example can be reproduced verbatim by
      # rerunning the file. If you change the seed, write the new seed
      # into the test (do not rely on the global default).
      SEED = 0x1217_5AFE

      # Required top-level payload keys (Requirement 6.3 / Property 4
      # invariant 3). Order-independent comparison via `sort`.
      REQUIRED_PAYLOAD_KEYS = %i[
        config
        runtime
        database
        framework
        environment
        systemInfo
        packageManager
      ].freeze

      # Required `payload[:config]` top-level keys (Requirement 13.2 /
      # Property 4 invariant 4). The actual config key set may be a
      # superset of this list, so the assertion is one-sided.
      REQUIRED_CONFIG_KEYS = %i[
        database
        adapter
        emailVerification
        emailAndPassword
        socialProviders
        plugins
        user
        verification
        session
        account
        hooks
        secondaryStorage
        advanced
        trustedOrigins
        rateLimit
        onAPIError
        logger
        databaseHooks
      ].freeze

      # Sample app names. The first entry is upstream's default
      # ("Better Auth"), which the project-name resolver intentionally
      # treats as "not configured"; the others are arbitrary.
      APP_NAMES = [
        "Better Auth",
        "AcmeApp",
        "test-host",
        "PropertyHarness",
        "rb-telemetry-spec"
      ].freeze

      # Sample base URLs. A `nil` base_url is also a valid input (it
      # falls through to one of the project_id derivation rules), so
      # the generator includes it.
      BASE_URLS = [
        nil,
        "https://example.com",
        "https://acme.test",
        "http://localhost:3000",
        "https://api.example.io/auth"
      ].freeze

      # Possible context override values for `:database` and
      # `:adapter`. Each is independently sampled per iteration.
      DB_CONTEXT_VALUES = [nil, "postgres", "mysql", "sqlite", "mongo"].freeze
      ADAPTER_CONTEXT_VALUES = [
        nil,
        "BetterAuth::Adapters::Memory",
        "BetterAuth::Adapters::Sequel",
        "BetterAuth::Adapters::ActiveRecord"
      ].freeze

      # ---------------------------------------------------------------------
      # Property 4: Init event top-level shape invariant.
      #
      # For any opted-in valid options hash and context, the emitted
      # init event SHALL have:
      #
      #   1. `event[:type] == "init"`,
      #   2. `event[:anonymousId]` is a non-empty `String`,
      #   3. `event[:payload].keys` is exactly the set
      #      `{:config, :runtime, :database, :framework, :environment,
      #        :systemInfo, :packageManager}`,
      #   4. `event[:payload][:config].keys` is a superset of the
      #      upstream `getTelemetryAuthConfig` top-level key set.
      #
      # Validates: Requirements 6.1, 6.3, 6.4, 13.2
      # ---------------------------------------------------------------------
      def test_property_4_init_event_top_level_shape
        rng = Random.new(SEED)

        ITERATIONS.times do |i|
          assert_init_event_shape_holds(rng: rng, iteration: i)
        end
      end

      private

      # Drive a single iteration of the property: build a random
      # `(options, context)` tuple, opt the process in via env, run
      # `Telemetry.create`, and assert all four invariants on the
      # recorded init event.
      def assert_init_event_shape_holds(rng:, iteration:)
        # The project_id memo is process-global; clear it between
        # iterations so a previous tuple's anonymous id resolution
        # does not pin onto this iteration's `base_url` /
        # `app_name` derivation.
        Telemetry.reset_project_id!

        options = generate_options(rng)
        context_hash, recorder = generate_context(rng)

        with_env(opt_in_env_overrides) do
          publisher = Telemetry.create(options, context_hash)

          assert_kind_of(
            Publisher,
            publisher,
            "iteration #{iteration}: expected an enabled Publisher with options=#{options.inspect}, context=#{context_hash.except(:custom_track).inspect}"
          )
          assert_predicate(
            publisher,
            :enabled?,
            "iteration #{iteration}: expected publisher.enabled? to be true"
          )

          events = recorder.events
          assert_equal(
            1,
            events.size,
            "iteration #{iteration}: expected exactly one init event, got #{events.size}"
          )

          event = events.first
          assert_invariant_1_type(event, iteration: iteration)
          assert_invariant_2_anonymous_id(event, iteration: iteration)
          assert_invariant_3_payload_keys(event, iteration: iteration)
          assert_invariant_4_config_keys(event, iteration: iteration)
        end
      ensure
        # Leave the cache clean for any later test that depends on a
        # cold project_id memo.
        Telemetry.reset_project_id!
      end

      # Invariant 1: `event[:type] == "init"`.
      def assert_invariant_1_type(event, iteration:)
        assert_kind_of(
          Hash,
          event,
          "iteration #{iteration}: emitted event must be a Hash"
        )
        assert_equal(
          "init",
          event[:type],
          "iteration #{iteration}: event[:type] must equal \"init\""
        )
      end

      # Invariant 2: `event[:anonymousId]` is a non-empty `String`.
      def assert_invariant_2_anonymous_id(event, iteration:)
        anon = event[:anonymousId]
        assert_kind_of(
          String,
          anon,
          "iteration #{iteration}: event[:anonymousId] must be a String, got #{anon.class}"
        )
        refute_predicate(
          anon,
          :empty?,
          "iteration #{iteration}: event[:anonymousId] must be non-empty"
        )
      end

      # Invariant 3: `event[:payload].keys` is exactly
      # `REQUIRED_PAYLOAD_KEYS` (camelCase preserved as Ruby symbol
      # keys).
      def assert_invariant_3_payload_keys(event, iteration:)
        payload = event[:payload]
        assert_kind_of(
          Hash,
          payload,
          "iteration #{iteration}: event[:payload] must be a Hash"
        )
        assert_equal(
          REQUIRED_PAYLOAD_KEYS.sort,
          payload.keys.sort,
          "iteration #{iteration}: payload.keys must equal the seven camelCase keys"
        )
      end

      # Invariant 4: `event[:payload][:config].keys` is a superset of
      # `REQUIRED_CONFIG_KEYS`. We allow the actual key set to be a
      # superset (the design's "SHALL be a superset" wording) so a
      # later Ruby-specific extension does not break the property.
      def assert_invariant_4_config_keys(event, iteration:)
        config = event.dig(:payload, :config)
        assert_kind_of(
          Hash,
          config,
          "iteration #{iteration}: event[:payload][:config] must be a Hash"
        )

        actual = config.keys
        missing = REQUIRED_CONFIG_KEYS - actual
        assert_empty(
          missing,
          "iteration #{iteration}: payload[:config].keys missing required keys #{missing.inspect}; actual keys #{actual.sort.inspect}"
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

      # Build a random valid options hash. The shape mirrors the
      # `BetterAuth::Configuration` option keys so the redaction map
      # in `Detectors::AuthConfig` has something meaningful to walk.
      # Each section is independently included/excluded so the
      # property exercises both the populated and the missing
      # branches of the redaction map.
      def generate_options(rng)
        opts = {
          telemetry: {enabled: true},
          app_name: APP_NAMES.sample(random: rng),
          base_url: BASE_URLS.sample(random: rng)
        }

        opts[:email_verification] = generate_email_verification(rng) if rng.rand < 0.7
        opts[:email_and_password] = generate_email_and_password(rng) if rng.rand < 0.7
        opts[:hooks] = generate_hooks(rng) if rng.rand < 0.5
        opts[:advanced] = generate_advanced(rng) if rng.rand < 0.6
        opts[:session] = generate_session(rng) if rng.rand < 0.4
        opts[:account] = generate_account(rng) if rng.rand < 0.4
        opts[:user] = generate_user(rng) if rng.rand < 0.4
        opts[:rate_limit] = generate_rate_limit(rng) if rng.rand < 0.3
        opts[:logger] = {disabled: rng.rand < 0.5, level: %w[info warn error].sample(random: rng)} if rng.rand < 0.3
        opts[:trusted_origins] = generate_trusted_origins(rng) if rng.rand < 0.4
        opts[:database_hooks] = generate_database_hooks(rng) if rng.rand < 0.3
        opts[:secondary_storage] = Object.new if rng.rand < 0.2
        opts[:plugins] = generate_plugins(rng) if rng.rand < 0.3

        opts
      end

      def generate_email_verification(rng)
        {
          send_verification_email: (rng.rand < 0.5) ? -> {} : nil,
          send_on_sign_up: rng.rand < 0.5,
          send_on_sign_in: rng.rand < 0.5,
          auto_sign_in_after_verification: rng.rand < 0.5,
          expires_in: 60 + rng.rand(86_400),
          before_email_verification: (rng.rand < 0.5) ? -> {} : nil,
          after_email_verification: (rng.rand < 0.5) ? -> {} : nil
        }
      end

      def generate_email_and_password(rng)
        {
          enabled: rng.rand < 0.7,
          disable_sign_up: rng.rand < 0.3,
          require_email_verification: rng.rand < 0.5,
          max_password_length: 64 + rng.rand(192),
          min_password_length: 6 + rng.rand(8),
          send_reset_password: (rng.rand < 0.5) ? -> {} : nil,
          reset_password_token_expires_in: 60 + rng.rand(86_400),
          on_password_reset: (rng.rand < 0.5) ? -> {} : nil,
          password: {
            hash: (rng.rand < 0.5) ? -> {} : nil,
            verify: (rng.rand < 0.5) ? -> {} : nil
          },
          auto_sign_in: rng.rand < 0.5,
          revoke_sessions_on_password_reset: rng.rand < 0.5
        }
      end

      def generate_hooks(rng)
        {
          before: (rng.rand < 0.5) ? -> {} : nil,
          after: (rng.rand < 0.5) ? -> {} : nil
        }
      end

      def generate_advanced(rng)
        {
          cookie_prefix: (rng.rand < 0.5) ? "ba" : nil,
          cookies: (rng.rand < 0.5) ? {session: {name: "s"}} : nil,
          cross_sub_domain_cookies: {
            domain: (rng.rand < 0.5) ? "example.com" : nil,
            enabled: rng.rand < 0.5,
            additional_cookies: (rng.rand < 0.5) ? %w[foo bar] : nil
          },
          database: {
            generate_id: (rng.rand < 0.5) ? -> {} : nil,
            default_find_many_limit: 10 + rng.rand(100)
          },
          use_secure_cookies: rng.rand < 0.5,
          ip_address: {
            disable_ip_tracking: rng.rand < 0.5,
            ip_address_headers: (rng.rand < 0.5) ? %w[X-Forwarded-For] : nil
          },
          disable_csrf_check: rng.rand < 0.5,
          default_cookie_attributes: {
            expires: 3600 + rng.rand(86_400),
            secure: rng.rand < 0.5,
            same_site: %w[Lax Strict None].sample(random: rng),
            domain: (rng.rand < 0.5) ? "example.com" : nil,
            path: "/",
            http_only: rng.rand < 0.5
          }
        }
      end

      def generate_session(rng)
        {
          model_name: "session",
          expires_in: 3600 + rng.rand(604_800),
          update_age: 60 + rng.rand(86_400),
          fresh_age: 60 + rng.rand(86_400),
          cookie_cache: {
            enabled: rng.rand < 0.5,
            max_age: 60 + rng.rand(3600),
            strategy: %w[jwe cookie].sample(random: rng)
          }
        }
      end

      def generate_account(rng)
        {
          model_name: "account",
          encrypt_oauth_tokens: rng.rand < 0.5,
          update_account_on_sign_in: rng.rand < 0.5,
          account_linking: {
            enabled: rng.rand < 0.5,
            trusted_providers: (rng.rand < 0.5) ? %w[google github] : nil,
            update_user_info_on_link: rng.rand < 0.5,
            allow_unlinking_all: rng.rand < 0.5
          }
        }
      end

      def generate_user(rng)
        {
          model_name: "user",
          fields: {email: "email_addr"},
          additional_fields: {role: {type: "string"}},
          change_email: {
            enabled: rng.rand < 0.5,
            send_change_email_confirmation: (rng.rand < 0.5) ? -> {} : nil
          }
        }
      end

      def generate_rate_limit(rng)
        {
          enabled: rng.rand < 0.5,
          window: 1 + rng.rand(60),
          max: 1 + rng.rand(100),
          model_name: "rate_limit",
          storage: %w[memory database secondary-storage].sample(random: rng),
          custom_storage: (rng.rand < 0.5) ? -> {} : nil
        }
      end

      def generate_trusted_origins(rng)
        count = rng.rand(5)
        Array.new(count) { |i| "https://trusted-#{i}.example.com" }
      end

      def generate_database_hooks(rng)
        models = %i[user session account verification]
        models.each_with_object({}) do |model, h|
          h[model] = {
            create: {
              before: (rng.rand < 0.5) ? -> {} : nil,
              after: (rng.rand < 0.5) ? -> {} : nil
            },
            update: {
              before: (rng.rand < 0.5) ? -> {} : nil,
              after: (rng.rand < 0.5) ? -> {} : nil
            }
          }
        end
      end

      def generate_plugins(rng)
        count = rng.rand(4)
        Array.new(count) do |i|
          plugin = Object.new
          id = "plugin-#{i}"
          plugin.define_singleton_method(:id) { id }
          plugin
        end
      end

      # Build a random context hash. Always wires a fresh
      # `RecordingTrack` as `custom_track` so the iteration's init
      # event is captured without HTTP. Every other field is sampled
      # independently. Returns the `[context_hash, recorder]` pair so
      # the caller can introspect the recorded events without keeping
      # a separate handle.
      def generate_context(rng)
        recorder = RecordingTrack.new

        ctx = {
          custom_track: recorder,
          # The Property 4 invariants assume the publisher is
          # opted-in. Always set `skip_test_check: true` so the
          # outer harness's RACK_ENV/RAILS_ENV/APP_ENV never matters
          # — the iteration controls those values via `with_env`
          # anyway, but pinning skip_test_check makes the property
          # robust against an inherited `RAILS_ENV=test` from the
          # parent process when the override hash misses a key.
          skip_test_check: true,
          database: DB_CONTEXT_VALUES.sample(random: rng),
          adapter: ADAPTER_CONTEXT_VALUES.sample(random: rng)
        }

        [ctx, recorder]
      end
    end
  end
end
