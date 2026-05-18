# frozen_string_literal: true

require "json"

require_relative "../../test_helper"
require_relative "../support/env_helpers"
require "better_auth"
require "better_auth/telemetry/detectors/auth_config"

# Property-based test for the boolean-redaction non-leaking
# guarantee — Property 11 of `design.md` § Correctness Properties.
#
# Property 11 — Boolean redaction is non-leaking
#   *For any* tuple `(field_path, secret_string)` where `field_path`
#   is one of the redaction-listed paths from the redaction map
#   (Section "Data Models → Configuration redaction map", "bool" or
#   "bool_present" helper) and `secret_string` is a non-empty
#   randomly generated `String`, setting the source-side options at
#   `field_path` to `secret_string` and computing
#   `payload = AuthConfig.call(options, {})` SHALL satisfy:
#     1. The value at the camelCase output path corresponding to
#        `field_path` in `payload` is `true` or `false` (a
#        `Boolean`), AND
#     2. `JSON.generate(payload)` does NOT contain `secret_string`
#        as a substring.
#
# `prop_check` is not currently bundled, so the property runs as a
# deterministic Minitest case driven by a seeded `Random`. The seed
# and iteration count are exposed as constants so a failing run can
# be reproduced byte-for-byte.
#
# The redaction-listed paths enumerated below cover the top-level
# redaction map plus the per-provider bool leaves under
# `social_providers[*]`. Together they exercise every top-level
# `bool`-helper section produced by {AuthConfig.call} (email
# verification, email-and-password, hooks, secondary storage,
# advanced cookie / domain redaction, rate-limit custom storage,
# on-API-error callable, logger callable, change-email
# confirmation, the full 16-leaf `databaseHooks` tree, and the
# per-provider bool leaves). The list does not need to be
# exhaustive — its purpose is to demonstrate that the property
# holds *across* the redaction map, not to retest every individual
# leaf, so callable-only edge cases that are already covered by
# unit tests (e.g. `secret`) are intentionally omitted.
#
# Validates: Requirements 13.3, 13.8
class RedactionPropertyTest < Minitest::Test
  AuthConfig = BetterAuth::Telemetry::Detectors::AuthConfig

  include BetterAuth::Telemetry::Test::EnvHelpers

  # Total number of randomized iterations. The design floor is 100;
  # we run a few extra to soak the variation across the redaction
  # map's branches (top-level scalar, nested hash, social-provider
  # entry, deeply nested `databaseHooks` leaf).
  ITERATIONS = 150

  # Fixed seed so a counter-example can be reproduced verbatim by
  # rerunning the file. If you change the seed, write the new seed
  # into the test (do not rely on the global default).
  SEED = 0xBEEF_CAFE

  # Provider id used when stamping a secret onto a
  # `social_providers[*]` leaf. A single id keeps the output array
  # at length one so the assertion can locate the redacted value
  # deterministically.
  SOCIAL_PROVIDER_ID = :github

  # Top-level (non-array) bool-redacted field paths. Each entry is
  # `[input_path, output_path]` where `input_path` is the snake_case
  # path to set on the source options hash and `output_path` is the
  # camelCase path the redacted value is expected to occupy in the
  # `AuthConfig.call` payload.
  #
  # Drawn from the design `Data Models → Configuration redaction
  # map` table for every row whose Helper column reads `bool` or
  # `bool_present`.
  TOP_LEVEL_BOOL_PATHS = [
    # email_verification
    [[:email_verification, :send_verification_email], [:emailVerification, :sendVerificationEmail]],
    [[:email_verification, :send_on_sign_up], [:emailVerification, :sendOnSignUp]],
    [[:email_verification, :send_on_sign_in], [:emailVerification, :sendOnSignIn]],
    [[:email_verification, :auto_sign_in_after_verification], [:emailVerification, :autoSignInAfterVerification]],
    [[:email_verification, :before_email_verification], [:emailVerification, :beforeEmailVerification]],
    [[:email_verification, :after_email_verification], [:emailVerification, :afterEmailVerification]],

    # email_and_password
    [[:email_and_password, :enabled], [:emailAndPassword, :enabled]],
    [[:email_and_password, :disable_sign_up], [:emailAndPassword, :disableSignUp]],
    [[:email_and_password, :require_email_verification], [:emailAndPassword, :requireEmailVerification]],
    [[:email_and_password, :send_reset_password], [:emailAndPassword, :sendResetPassword]],
    [[:email_and_password, :on_password_reset], [:emailAndPassword, :onPasswordReset]],
    [[:email_and_password, :auto_sign_in], [:emailAndPassword, :autoSignIn]],
    [[:email_and_password, :revoke_sessions_on_password_reset], [:emailAndPassword, :revokeSessionsOnPasswordReset]],
    [[:email_and_password, :password, :hash], [:emailAndPassword, :password, :hash]],
    [[:email_and_password, :password, :verify], [:emailAndPassword, :password, :verify]],

    # user
    [[:user, :change_email, :send_change_email_confirmation], [:user, :changeEmail, :sendChangeEmailConfirmation]],

    # hooks
    [[:hooks, :before], [:hooks, :before]],
    [[:hooks, :after], [:hooks, :after]],

    # secondary_storage (top-level)
    [[:secondary_storage], [:secondaryStorage]],

    # advanced
    [[:advanced, :cookie_prefix], [:advanced, :cookiePrefix]],
    [[:advanced, :cookies], [:advanced, :cookies]],
    [[:advanced, :cross_sub_domain_cookies, :domain], [:advanced, :crossSubDomainCookies, :domain]],
    [[:advanced, :default_cookie_attributes, :domain], [:advanced, :cookieAttributes, :domain]],

    # rate_limit
    [[:rate_limit, :custom_storage], [:rateLimit, :customStorage]],

    # on_api_error
    [[:on_api_error, :on_error], [:onAPIError, :onError]],

    # logger
    [[:logger, :log], [:logger, :log]]
  ].freeze

  # Per-provider bool-redacted leaves. The input path is the
  # snake_case key on a single `social_providers[<provider_id>]`
  # entry; the output path locates the redacted value inside
  # `payload[:socialProviders][0]` (we always seed exactly one
  # provider so the entry index is fixed).
  SOCIAL_PROVIDER_BOOL_PATHS = [
    [:map_profile_to_user, :mapProfileToUser],
    [:disable_default_scope, :disableDefaultScope],
    [:disable_id_token_sign_in, :disableIdTokenSignIn],
    [:get_user_info, :getUserInfo],
    [:override_user_info_on_sign_in, :overrideUserInfoOnSignIn],
    [:verify_id_token, :verifyIdToken],
    [:refresh_access_token, :refreshAccessToken]
  ].freeze

  # Pre-built list of every (model, operation, phase) tuple under
  # `database_hooks`. Every leaf is bool-redacted (Requirement 13.3
  # / 13.8), giving 16 paths in total.
  DATABASE_HOOK_BOOL_PATHS = AuthConfig::DATABASE_HOOK_MODELS.flat_map do |model|
    AuthConfig::DATABASE_HOOK_OPERATIONS.flat_map do |operation|
      AuthConfig::DATABASE_HOOK_PHASES.map do |phase|
        [
          [:database_hooks, model, operation, phase],
          [:databaseHooks, model, operation, phase]
        ]
      end
    end
  end.freeze

  # Alphabet for the per-iteration secret string. ASCII letters /
  # digits keep the secret JSON-safe (no escaping surprises that
  # could mask a substring leak) and high-cardinality enough that
  # an accidental collision with anything in the payload is
  # vanishingly unlikely at the iteration counts we run.
  SECRET_ALPHABET = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a

  # ---------------------------------------------------------------------
  # Property 11: Boolean redaction is non-leaking.
  # Validates: Requirements 13.3, 13.8
  # ---------------------------------------------------------------------
  def test_property_11_boolean_redaction_is_non_leaking
    rng = Random.new(SEED)
    paths = build_path_pool

    ITERATIONS.times do |i|
      with_clean_telemetry_env do
        input_path, output_path = paths.sample(random: rng)
        secret = generate_secret_string(rng)

        options = build_options_with_secret(input_path, secret)
        payload = AuthConfig.call(options, {})

        refute_nil payload,
          "iteration #{i}: AuthConfig.call returned nil for path #{input_path.inspect} " \
          "(secret=#{secret.inspect})"

        actual = dig_payload(payload, output_path)
        assert_boolean(
          actual,
          "iteration #{i}: payload value at #{output_path.inspect} must be Boolean, " \
          "got #{actual.inspect} (input_path=#{input_path.inspect}, secret=#{secret.inspect})"
        )

        json = JSON.generate(payload)
        refute_includes json, secret,
          "iteration #{i}: secret #{secret.inspect} leaked into JSON.generate(payload) " \
          "for input_path=#{input_path.inspect} output_path=#{output_path.inspect}"
      end
    end
  end

  private

  # Build the pool of `[input_path, output_path]` tuples sampled by
  # the property. Combines the top-level paths, the per-provider
  # paths (each rewritten to its full payload-side location), and
  # the full 16-leaf `database_hooks` tree.
  def build_path_pool
    social_paths = SOCIAL_PROVIDER_BOOL_PATHS.map do |input_leaf, output_leaf|
      [
        [:social_providers, SOCIAL_PROVIDER_ID, input_leaf],
        [:socialProviders, 0, output_leaf]
      ]
    end

    TOP_LEVEL_BOOL_PATHS + social_paths + DATABASE_HOOK_BOOL_PATHS
  end

  # Run a block with the env vars that
  # `BetterAuth::Configuration#normalize_trusted_origins` and the
  # production-environment branch of `normalize_rate_limit` would
  # otherwise fold into the normalized configuration cleared. We
  # also clear the `RACK_ENV` / `RAILS_ENV` / `APP_ENV` markers so
  # the test's own environment cannot leak into the payload.
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

  # Generate a non-empty random alphanumeric `String`. The length is
  # bounded between 8 and 32 characters so the secret is long
  # enough to be statistically unique across iterations but short
  # enough that JSON encoding cost stays negligible.
  def generate_secret_string(rng)
    length = 8 + rng.rand(25) # 8..32 inclusive
    Array.new(length) { SECRET_ALPHABET.sample(random: rng) }.join
  end

  # Build a minimal options hash that places `secret` at the given
  # `input_path`. The `social_providers` branch wraps the secret
  # under a fixed provider id so the provider entry's array index
  # is deterministic; every other branch builds nested
  # symbol-keyed hashes from the path segments, leaf-first.
  #
  # We deliberately do not pre-seed any other fields: the redaction
  # map's other helpers tolerate `nil` (they collapse via `bool` to
  # `false`, raw scalars stay `nil`), so a sparse hash exercises
  # the property without dragging in unrelated leaves.
  def build_options_with_secret(input_path, secret)
    case input_path[0]
    when :social_providers
      _, provider_id, leaf = input_path
      {social_providers: {provider_id => {leaf => secret}}}
    else
      build_nested_hash(input_path, secret)
    end
  end

  # Build a chain of single-key symbol-keyed hashes ending with the
  # leaf value. `path = [:a, :b, :c], leaf = "x"` produces
  # `{a: {b: {c: "x"}}}`.
  def build_nested_hash(path, leaf_value)
    path.reverse.inject(leaf_value) { |acc, key| {key => acc} }
  end

  # Walk `payload` using the camelCase output path. Each segment is
  # either a `Symbol` (hash key) or an `Integer` (array index, used
  # by the `social_providers` mapping where the redacted entry sits
  # at index `0`).
  def dig_payload(payload, output_path)
    output_path.inject(payload) do |current, segment|
      case current
      when Hash then current[segment]
      when Array then current[segment]
      end
    end
  end

  # Strict Boolean assertion. `assert_includes [true, false], value`
  # is too loose — it accepts truthy/falsy objects via `==` —
  # whereas Property 11 demands the concrete `TrueClass` /
  # `FalseClass` values upstream produces.
  def assert_boolean(value, message)
    assert(value == true || value == false, message)
  end
end
