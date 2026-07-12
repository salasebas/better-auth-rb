# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/env_helpers"
require "better_auth"
require "better_auth/telemetry/detectors/auth_config"
require "better_auth/telemetry/options"

# Property-based tests for the AuthConfig leaf-shape and dual-input
# invariants — Properties 5 and 10 of `design.md` § Correctness
# Properties.
#
# Property 5 — AuthConfig leaf shape conformance
#   *For any* valid options:
#     1. `payload[:config][:socialProviders]` is an `Array` whose
#        every element is a `Hash` containing the keys `id`,
#        `mapProfileToUser`, `disableDefaultScope`,
#        `disableIdTokenSignIn`, `disableImplicitSignUp`,
#        `disableSignUp`, `getUserInfo`, `overrideUserInfoOnSignIn`,
#        `prompt`, `verifyIdToken`, `scope`, `refreshAccessToken`,
#     2. `payload[:config][:plugins]` is either `nil` or an `Array`
#        of `String`s,
#     3. `payload[:config][:trustedOrigins]` is either `nil` or an
#        `Integer` equal to the count of configured origins.
#
# Property 10 — AuthConfig is invariant under input shape
#   *For any* raw options hash `H` whose contents are valid for
#   {BetterAuth::Configuration.new}, the values
#   `AuthConfig.call(BetterAuth::Configuration.new(H), ctx)` and
#   `AuthConfig.call(H, ctx)` are deep-equal.
#
# `prop_check` is not currently bundled, so the property runs as a
# deterministic Minitest case driven by a seeded `Random`. The seed
# and iteration count are exposed as constants so a failing run can
# be reproduced byte-for-byte.
#
# The generator builds a "logical" options hash that mirrors what
# {BetterAuth::Configuration#initialize} produces post-normalization
# (defaults from `DEFAULT_EMAIL_AND_PASSWORD` / `DEFAULT_SESSION`
# pre-populated, rate-limit fields fully set, `database: :memory`
# pinned so stateless branches stay quiet) — the same trick used by
# `auth_config_input_shape_test.rb`. Trusted-origin / base-url env
# vars are cleared via {EnvHelpers#with_env} so
# `Configuration#normalize_trusted_origins` cannot inflate the
# array behind our back.
#
# Validates: Requirements 13.1, 13.5, 13.6, 13.7
class AuthConfigShapePropertyTest < Minitest::Test
  CANONICAL_BASE_URL = "https://auth.example.com"
  AuthConfig = BetterAuth::Telemetry::Detectors::AuthConfig
  NormalizedContext = BetterAuth::Telemetry::NormalizedContext

  include BetterAuth::Telemetry::Test::EnvHelpers

  # Total number of randomized iterations. The design floor is 100;
  # we run a few extra to soak the variation across the generator's
  # option-section permutations.
  ITERATIONS = 120

  # Fixed seed so a counter-example can be reproduced verbatim by
  # rerunning the file. If you change the seed, write the new seed
  # into the test (do not rely on the global default).
  SEED = 0xA5C0_F105

  # Documented camelCase key set for every entry in
  # `payload[:socialProviders]` (Requirement 13.5).
  SOCIAL_PROVIDER_KEYS = %i[
    id
    mapProfileToUser
    disableDefaultScope
    disableIdTokenSignIn
    disableImplicitSignUp
    disableSignUp
    getUserInfo
    overrideUserInfoOnSignIn
    prompt
    verifyIdToken
    scope
    refreshAccessToken
  ].freeze

  # Provider ids drawn for the `social_providers` generator. Picking
  # from a small fixed pool ensures the iteration's hash key set
  # exercises both the "single populated provider" and the "several
  # mixed providers" branches without ballooning shrink space.
  PROVIDER_IDS = %i[github google discord apple facebook].freeze

  # Possible values for `social_providers[*].prompt`. Includes `nil`
  # so the empty-options branch is exercised.
  PROMPT_VALUES = [nil, "consent", "login", "select_account", "none"].freeze

  # Possible values for `rate_limit.storage`. Picking from a fixed
  # set keeps the redactor's raw pass-through assertion honest while
  # avoiding the `secondary_storage`-derived default branch in
  # {BetterAuth::Configuration#normalize_rate_limit}.
  RATE_LIMIT_STORAGES = %w[memory database secondary-storage].freeze

  # Possible logger levels.
  LOGGER_LEVELS = %w[debug info warn error].freeze

  # Possible same-site values for the cookie attributes block.
  SAME_SITE_VALUES = %w[Lax Strict None].freeze

  # ---------------------------------------------------------------------
  # Property 5: AuthConfig leaf shape conformance.
  # Validates: Requirements 13.5, 13.6, 13.7
  # ---------------------------------------------------------------------
  def test_property_5_auth_config_leaf_shape_conformance
    rng = Random.new(SEED)

    ITERATIONS.times do |i|
      with_clean_telemetry_env do
        options = generate_logical_options(rng)

        payload_from_config = AuthConfig.call(BetterAuth::Configuration.new(options), nil)
        payload_from_hash = AuthConfig.call(options, nil)

        assert_property_5_holds(
          payload_from_config,
          options,
          label: "iteration #{i} (Configuration input)"
        )
        assert_property_5_holds(
          payload_from_hash,
          options,
          label: "iteration #{i} (raw Hash input)"
        )
      end
    end
  end

  # ---------------------------------------------------------------------
  # Property 10: AuthConfig is invariant under input shape.
  # Validates: Requirement 13.1
  # ---------------------------------------------------------------------
  def test_property_10_auth_config_invariant_under_input_shape
    rng = Random.new(SEED)

    ITERATIONS.times do |i|
      with_clean_telemetry_env do
        options = generate_logical_options(rng)
        ctx = generate_context(rng)

        payload_from_config = AuthConfig.call(BetterAuth::Configuration.new(options), ctx)
        payload_from_hash = AuthConfig.call(options, ctx)

        refute_nil payload_from_config,
          "iteration #{i}: AuthConfig.call(Configuration, ctx) returned nil"
        refute_nil payload_from_hash,
          "iteration #{i}: AuthConfig.call(Hash, ctx) returned nil"
        assert_equal payload_from_config, payload_from_hash,
          "iteration #{i}: AuthConfig payload differs between Configuration and raw-hash inputs"
      end
    end
  end

  private

  # Run a block with the env vars that
  # {BetterAuth::Configuration#normalize_trusted_origins} and the
  # production-environment branch of `normalize_rate_limit` would
  # otherwise fold into the normalized configuration cleared. We
  # also clear `RACK_ENV`/`RAILS_ENV`/`APP_ENV` so the test's own
  # environment cannot inadvertently flip the rate-limit `enabled`
  # default.
  def with_clean_telemetry_env(&block)
    with_env(
      "BETTER_AUTH_TRUSTED_ORIGINS" => nil,
      "BETTER_AUTH_URL" => nil,
      "BASE_URL" => nil,
      "BETTER_AUTH_ENV" => nil,
      "RACK_ENV" => nil,
      "RAILS_ENV" => nil,
      "APP_ENV" => nil,
      &block
    )
  end

  # Assert Property 5's three invariants against `payload`.
  def assert_property_5_holds(payload, options, label:)
    refute_nil payload, "#{label}: AuthConfig.call returned nil"

    assert_property_5_invariant_1_social_providers(payload, label: label)
    assert_property_5_invariant_2_plugins(payload, label: label)
    assert_property_5_invariant_3_trusted_origins(payload, options, label: label)
  end

  # Invariant 1: `payload[:socialProviders]` is an `Array` whose
  # every element is a `Hash` containing exactly the documented
  # camelCase key set (Requirement 13.5).
  def assert_property_5_invariant_1_social_providers(payload, label:)
    providers = payload[:socialProviders]
    assert_kind_of Array, providers,
      "#{label}: payload[:socialProviders] must be Array, got #{providers.class}"

    providers.each_with_index do |entry, idx|
      assert_kind_of Hash, entry,
        "#{label}: payload[:socialProviders][#{idx}] must be Hash, got #{entry.class}"
      assert_equal SOCIAL_PROVIDER_KEYS.sort, entry.keys.sort,
        "#{label}: payload[:socialProviders][#{idx}] keys must equal documented set"
    end
  end

  # Invariant 2: `payload[:plugins]` is either `nil` or an `Array`
  # of `String`s (Requirement 13.6).
  def assert_property_5_invariant_2_plugins(payload, label:)
    plugins = payload[:plugins]
    return if plugins.nil?

    assert_kind_of Array, plugins,
      "#{label}: payload[:plugins] must be nil or Array, got #{plugins.class}"
    plugins.each_with_index do |id, idx|
      assert_kind_of String, id,
        "#{label}: payload[:plugins][#{idx}] must be String, got #{id.class}"
    end
  end

  # Invariant 3: `payload[:trustedOrigins]` is either `nil` or an
  # `Integer` equal to the count of configured origins
  # (Requirement 13.7).
  #
  # The generator always sets `:trusted_origins` to a clean (no
  # duplicates, no empty / nil entries) `Array`, so the count
  # produced by both the Configuration and raw-hash branches is the
  # literal length of the configured array.
  def assert_property_5_invariant_3_trusted_origins(payload, options, label:)
    actual = payload[:trustedOrigins]
    configured = options[:trusted_origins]

    if configured.nil?
      assert_nil actual,
        "#{label}: payload[:trustedOrigins] must be nil when no origins configured"
      return
    end

    assert_kind_of Integer, actual,
      "#{label}: payload[:trustedOrigins] must be Integer, got #{actual.class}"
    assert_equal Array(configured).length, actual,
      "#{label}: payload[:trustedOrigins] must equal count of configured origins"
  end

  # Build a logical options hash that survives both the
  # Configuration-input and the raw-hash-input branches of
  # {AuthConfig.call} without drift. Every leaf the redactor reads
  # is supplied (or pre-filled with the same default
  # {BetterAuth::Configuration} would inject) so that
  # `AuthConfig.call(Configuration.new(H), ctx)` and
  # `AuthConfig.call(H, ctx)` produce deep-equal payloads.
  #
  # Section-by-section notes:
  # * `email_and_password.{min,max}_password_length` mirror
  #   `Configuration::DEFAULT_EMAIL_AND_PASSWORD`.
  # * `session.{update_age,expires_in,fresh_age}` mirror
  #   `Configuration::DEFAULT_SESSION`.
  # * `database: :memory` keeps `normalize_session` /
  #   `normalize_account` out of the stateless branches that would
  #   otherwise inject `cookie_cache.*` / `store_state_strategy`
  #   defaults the raw-hash side does not know about.
  # * `rate_limit` is fully populated so `normalize_rate_limit`'s
  #   default-fill branches are inert.
  # * `trusted_origins` is always an array of unique, non-empty URLs
  #   so `Array(value).compact.uniq.length` equals the literal
  #   length on both branches.
  def generate_logical_options(rng)
    {
      secret: "0" * 40,
      database: :memory,
      app_name: (rng.rand < 0.5) ? "AcmeApp" : "Better Auth",
      base_url: CANONICAL_BASE_URL,
      email_verification: generate_email_verification(rng),
      email_and_password: generate_email_and_password(rng),
      session: generate_session(rng),
      account: generate_account(rng),
      user: generate_user(rng),
      verification: generate_verification(rng),
      hooks: generate_hooks(rng),
      secondary_storage: (rng.rand < 0.5) ? "redis-storage" : nil,
      advanced: generate_advanced(rng),
      trusted_origins: generate_trusted_origins(rng),
      rate_limit: generate_rate_limit(rng),
      on_api_error: generate_on_api_error(rng),
      logger: generate_logger(rng),
      social_providers: generate_social_providers(rng),
      plugins: generate_plugins(rng),
      database_hooks: generate_database_hooks(rng)
    }
  end

  def generate_email_verification(rng)
    {
      send_verification_email: (rng.rand < 0.5) ? ->(*) {} : nil,
      send_on_sign_up: rng.rand < 0.5,
      send_on_sign_in: rng.rand < 0.5,
      auto_sign_in_after_verification: rng.rand < 0.5,
      expires_in: 60 + rng.rand(86_400),
      before_email_verification: (rng.rand < 0.5) ? ->(*) {} : nil,
      after_email_verification: (rng.rand < 0.5) ? ->(*) {} : nil
    }
  end

  def generate_email_and_password(rng)
    {
      enabled: rng.rand < 0.7,
      disable_sign_up: rng.rand < 0.3,
      require_email_verification: rng.rand < 0.5,
      max_password_length: 64 + rng.rand(192),
      min_password_length: 6 + rng.rand(8),
      send_reset_password: (rng.rand < 0.5) ? ->(*) {} : nil,
      reset_password_token_expires_in: 60 + rng.rand(86_400),
      on_password_reset: (rng.rand < 0.5) ? ->(*) {} : nil,
      password: {
        hash: (rng.rand < 0.5) ? ->(*) {} : nil,
        verify: (rng.rand < 0.5) ? ->(*) {} : nil
      },
      auto_sign_in: rng.rand < 0.5,
      revoke_sessions_on_password_reset: rng.rand < 0.5
    }
  end

  def generate_session(rng)
    {
      model_name: "session",
      expires_in: 3600 + rng.rand(604_800),
      update_age: 60 + rng.rand(86_400),
      fresh_age: 60 + rng.rand(86_400)
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
        send_change_email_confirmation: (rng.rand < 0.5) ? ->(*) {} : nil
      }
    }
  end

  def generate_verification(rng)
    {
      model_name: "verification",
      disable_cleanup: rng.rand < 0.5,
      fields: {identifier: "ident"}
    }
  end

  def generate_hooks(rng)
    {
      before: (rng.rand < 0.5) ? ->(*) {} : nil,
      after: (rng.rand < 0.5) ? ->(*) {} : nil
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
        generate_id: (rng.rand < 0.5) ? ->(*) {} : nil,
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
        same_site: SAME_SITE_VALUES.sample(random: rng),
        domain: (rng.rand < 0.5) ? "example.com" : nil,
        path: "/",
        http_only: rng.rand < 0.5
      }
    }
  end

  # Always returns a clean Array (no duplicates, no empty entries)
  # so that `Configuration#normalize_trusted_origins`'s
  # `.map(&:to_s).reject(&:empty?).uniq` cannot trim the configured
  # length away from the literal `Array#length` the raw-hash branch
  # sees.
  def generate_trusted_origins(rng)
    count = rng.rand(5)
    [CANONICAL_BASE_URL] + Array.new(count) { |i| "https://trusted-#{i}.example.com" }
  end

  def generate_rate_limit(rng)
    {
      enabled: rng.rand < 0.5,
      window: 1 + rng.rand(60),
      max: 1 + rng.rand(100),
      model_name: "rate_limit",
      storage: RATE_LIMIT_STORAGES.sample(random: rng),
      custom_storage: (rng.rand < 0.5) ? ->(*) {} : nil
    }
  end

  def generate_on_api_error(rng)
    {
      error_url: (rng.rand < 0.5) ? "/error" : nil,
      on_error: (rng.rand < 0.5) ? ->(*) {} : nil,
      throw: rng.rand < 0.5
    }
  end

  def generate_logger(rng)
    {
      disabled: rng.rand < 0.5,
      level: LOGGER_LEVELS.sample(random: rng),
      log: (rng.rand < 0.5) ? ->(*) {} : nil
    }
  end

  # Build a `social_providers` hash with 0..3 providers drawn from
  # {PROVIDER_IDS}. Each provider is independently populated or
  # left bare, so the iteration exercises both the
  # "callable-redacts-to-true" and "missing-key-redacts-to-false"
  # branches of the social-provider redactor.
  def generate_social_providers(rng)
    count = rng.rand(PROVIDER_IDS.length + 1) # 0..length
    selected = PROVIDER_IDS.sample(count, random: rng)
    selected.each_with_object({}) do |provider_id, providers|
      providers[provider_id] = generate_provider_options(rng)
    end
  end

  def generate_provider_options(rng)
    return {} if rng.rand < 0.3

    {
      map_profile_to_user: (rng.rand < 0.5) ? ->(*) {} : nil,
      disable_default_scope: rng.rand < 0.5,
      disable_id_token_sign_in: rng.rand < 0.5,
      disable_implicit_sign_up: rng.rand < 0.5,
      disable_sign_up: rng.rand < 0.5,
      get_user_info: (rng.rand < 0.5) ? ->(*) {} : nil,
      override_user_info_on_sign_in: rng.rand < 0.5,
      prompt: PROMPT_VALUES.sample(random: rng),
      verify_id_token: (rng.rand < 0.5) ? ->(*) {} : nil,
      scope: (rng.rand < 0.5) ? %w[email profile] : nil,
      refresh_access_token: (rng.rand < 0.5) ? ->(*) {} : nil
    }
  end

  # Build a `plugins` array with 0..3 plugin instances. We use
  # actual {BetterAuth::Plugin} instances so
  # `Configuration#normalize_plugins`'s `Plugin.coerce` is a no-op
  # (Plugin.coerce returns the value unchanged when it is already a
  # Plugin), keeping the Configuration- and raw-hash-side plugin
  # arrays object-identical for the redactor.
  def generate_plugins(rng)
    count = rng.rand(4) # 0..3
    Array.new(count) { |i| BetterAuth::Plugin.new(id: "plugin-#{i}") }
  end

  def generate_database_hooks(rng)
    AuthConfig::DATABASE_HOOK_MODELS.each_with_object({}) do |model, h|
      h[model] = AuthConfig::DATABASE_HOOK_OPERATIONS.each_with_object({}) do |operation, ops|
        ops[operation] = AuthConfig::DATABASE_HOOK_PHASES.each_with_object({}) do |phase, phases|
          phases[phase] = (rng.rand < 0.5) ? ->(*) {} : nil
        end
      end
    end
  end

  # Build a context for Property 10. Each iteration alternates
  # between `nil`, a raw symbol-keyed hash, and a fully-formed
  # {NormalizedContext} so the assertion exercises all three of the
  # accepted context shapes (Requirement 13.9).
  def generate_context(rng)
    case rng.rand(3)
    when 0
      nil
    when 1
      {database: "ctx-db-#{rng.rand(100)}", adapter: "CtxAdapter#{rng.rand(100)}"}
    else
      NormalizedContext.from(
        database: "norm-db-#{rng.rand(100)}",
        adapter: "NormAdapter#{rng.rand(100)}"
      )
    end
  end
end
