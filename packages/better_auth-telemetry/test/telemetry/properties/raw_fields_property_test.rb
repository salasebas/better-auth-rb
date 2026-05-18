# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/env_helpers"
require "better_auth"
require "better_auth/telemetry/detectors/auth_config"

# Property-based test for raw-field verbatim preservation —
# Property 12 of `design.md` § Correctness Properties.
#
# Property 12 — Raw fields are preserved verbatim
#   *For any* tuple `(field_path, scalar_value)` where `field_path`
#   is one of the raw-listed paths from the redaction map (Section
#   "Data Models → Configuration redaction map", `raw` helper) and
#   `scalar_value` is any JSON-encodable Ruby scalar (`Integer`,
#   `String`, `true`, `false`, `nil`), the value at `field_path`
#   in `AuthConfig.call(options, {})` SHALL equal `scalar_value`
#   (`==`).
#
# `prop_check` is not currently bundled, so the property runs as
# a deterministic Minitest case driven by a seeded `Random`. The
# seed and iteration count are exposed as constants so a failing
# run can be reproduced byte-for-byte.
#
# The raw-listed paths enumerated below cover every row of the
# redaction map whose Helper column reads `raw`. Each row is
# expressed as `[input_path, output_path]` where `input_path` is
# the snake_case path to set on the source options hash and
# `output_path` is the camelCase path the value is expected to
# occupy in the `AuthConfig.call` payload.
#
# The list intentionally includes the upstream rename from the
# Ruby source key `default_cookie_attributes` to the upstream
# wire key `cookieAttributes` so the property exercises both
# straight key passthroughs and the renamed branch.
#
# Validates: Requirements 13.4
class RawFieldsPropertyTest < Minitest::Test
  AuthConfig = BetterAuth::Telemetry::Detectors::AuthConfig

  include BetterAuth::Telemetry::Test::EnvHelpers

  # Total number of randomized iterations. The design floor is 100;
  # we run a few extra to soak the variation across the raw-field
  # map's branches (top-level scalar, nested hash, renamed
  # `cookieAttributes` branch).
  ITERATIONS = 150

  # Fixed seed so a counter-example can be reproduced verbatim by
  # rerunning the file. If you change the seed, write the new seed
  # into the test (do not rely on the global default).
  SEED = 0xF1E1D5_C0DE_BEEF

  # Top-level (non-array) raw-redacted field paths. Each entry is
  # `[input_path, output_path]` where `input_path` is the
  # snake_case path to set on the source options hash and
  # `output_path` is the camelCase path the value is expected to
  # occupy in the `AuthConfig.call` payload.
  #
  # Drawn from the design `Data Models → Configuration redaction
  # map` table for every row whose Helper column reads `raw`.
  RAW_FIELD_PATHS = [
    # email_verification
    [[:email_verification, :expires_in], [:emailVerification, :expiresIn]],

    # email_and_password
    [[:email_and_password, :max_password_length], [:emailAndPassword, :maxPasswordLength]],
    [[:email_and_password, :min_password_length], [:emailAndPassword, :minPasswordLength]],
    [[:email_and_password, :reset_password_token_expires_in], [:emailAndPassword, :resetPasswordTokenExpiresIn]],

    # user
    [[:user, :model_name], [:user, :modelName]],
    [[:user, :fields], [:user, :fields]],
    [[:user, :additional_fields], [:user, :additionalFields]],
    [[:user, :change_email, :enabled], [:user, :changeEmail, :enabled]],

    # verification
    [[:verification, :model_name], [:verification, :modelName]],
    [[:verification, :disable_cleanup], [:verification, :disableCleanup]],
    [[:verification, :fields], [:verification, :fields]],

    # session
    [[:session, :model_name], [:session, :modelName]],
    [[:session, :additional_fields], [:session, :additionalFields]],
    [[:session, :cookie_cache, :enabled], [:session, :cookieCache, :enabled]],
    [[:session, :cookie_cache, :max_age], [:session, :cookieCache, :maxAge]],
    [[:session, :cookie_cache, :strategy], [:session, :cookieCache, :strategy]],
    [[:session, :disable_session_refresh], [:session, :disableSessionRefresh]],
    [[:session, :expires_in], [:session, :expiresIn]],
    [[:session, :fields], [:session, :fields]],
    [[:session, :fresh_age], [:session, :freshAge]],
    [[:session, :preserve_session_in_database], [:session, :preserveSessionInDatabase]],
    [[:session, :store_session_in_database], [:session, :storeSessionInDatabase]],
    [[:session, :update_age], [:session, :updateAge]],

    # account
    [[:account, :model_name], [:account, :modelName]],
    [[:account, :fields], [:account, :fields]],
    [[:account, :encrypt_oauth_tokens], [:account, :encryptOAuthTokens]],
    [[:account, :update_account_on_sign_in], [:account, :updateAccountOnSignIn]],
    [[:account, :account_linking, :enabled], [:account, :accountLinking, :enabled]],
    [[:account, :account_linking, :trusted_providers], [:account, :accountLinking, :trustedProviders]],
    [[:account, :account_linking, :update_user_info_on_link], [:account, :accountLinking, :updateUserInfoOnLink]],
    [[:account, :account_linking, :allow_unlinking_all], [:account, :accountLinking, :allowUnlinkingAll]],

    # advanced
    [[:advanced, :cross_sub_domain_cookies, :enabled], [:advanced, :crossSubDomainCookies, :enabled]],
    [[:advanced, :cross_sub_domain_cookies, :additional_cookies], [:advanced, :crossSubDomainCookies, :additionalCookies]],
    [[:advanced, :database, :generate_id], [:advanced, :database, :generateId]],
    [[:advanced, :database, :default_find_many_limit], [:advanced, :database, :defaultFindManyLimit]],
    [[:advanced, :use_secure_cookies], [:advanced, :useSecureCookies]],
    [[:advanced, :ip_address, :disable_ip_tracking], [:advanced, :ipAddress, :disableIpTracking]],
    [[:advanced, :ip_address, :ip_address_headers], [:advanced, :ipAddress, :ipAddressHeaders]],
    [[:advanced, :disable_csrf_check], [:advanced, :disableCSRFCheck]],
    # Source key `default_cookie_attributes` is renamed to upstream
    # wire key `cookieAttributes` (Requirement 13.7).
    [[:advanced, :default_cookie_attributes, :expires], [:advanced, :cookieAttributes, :expires]],
    [[:advanced, :default_cookie_attributes, :secure], [:advanced, :cookieAttributes, :secure]],
    [[:advanced, :default_cookie_attributes, :same_site], [:advanced, :cookieAttributes, :sameSite]],
    [[:advanced, :default_cookie_attributes, :path], [:advanced, :cookieAttributes, :path]],
    [[:advanced, :default_cookie_attributes, :http_only], [:advanced, :cookieAttributes, :httpOnly]],

    # rate_limit
    [[:rate_limit, :storage], [:rateLimit, :storage]],
    [[:rate_limit, :model_name], [:rateLimit, :modelName]],
    [[:rate_limit, :window], [:rateLimit, :window]],
    [[:rate_limit, :enabled], [:rateLimit, :enabled]],
    [[:rate_limit, :max], [:rateLimit, :max]],

    # on_api_error
    [[:on_api_error, :error_url], [:onAPIError, :errorURL]],
    [[:on_api_error, :throw], [:onAPIError, :throw]],

    # logger
    [[:logger, :disabled], [:logger, :disabled]],
    [[:logger, :level], [:logger, :level]]
  ].freeze

  # Alphabet for the per-iteration `String` scalar. ASCII letters
  # / digits keep the value JSON-safe and high-cardinality enough
  # that an accidental collision with anything in the payload is
  # vanishingly unlikely at the iteration counts we run.
  SCALAR_STRING_ALPHABET = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a

  # Bound on the absolute value of the `Integer` scalar. Wide
  # enough to exercise multi-digit values (so a stringified
  # representation cannot accidentally match unrelated bytes in
  # the payload) but small enough to keep the `inspect` output
  # readable in failure messages.
  SCALAR_INTEGER_BOUND = 1_000_000

  # ---------------------------------------------------------------------
  # Property 12: Raw fields are preserved verbatim.
  # Validates: Requirements 13.4
  # ---------------------------------------------------------------------
  def test_property_12_raw_fields_are_preserved_verbatim
    rng = Random.new(SEED)

    ITERATIONS.times do |i|
      with_clean_telemetry_env do
        input_path, output_path = RAW_FIELD_PATHS.sample(random: rng)
        scalar = generate_scalar(rng)

        options = build_nested_hash(input_path, scalar)
        payload = AuthConfig.call(options, {})

        refute_nil payload,
          "iteration #{i}: AuthConfig.call returned nil for path #{input_path.inspect} " \
          "(scalar=#{scalar.inspect})"

        actual = dig_payload(payload, output_path)
        if scalar.nil?
          assert_nil actual,
            "iteration #{i}: payload value at #{output_path.inspect} must be nil " \
            "(matching input scalar nil at #{input_path.inspect}); got #{actual.inspect}"
        else
          assert_equal scalar, actual,
            "iteration #{i}: payload value at #{output_path.inspect} must equal " \
            "input scalar at #{input_path.inspect}; expected #{scalar.inspect}, got #{actual.inspect}"
        end
      end
    end
  end

  private

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

  # Pick one of the five JSON-encodable scalar shapes uniformly at
  # random and materialize a fresh value. The five shapes mirror
  # the design's enumeration of Ruby's JSON-encodable scalars:
  # `Integer`, `String`, `true`, `false`, `nil`.
  def generate_scalar(rng)
    case rng.rand(5)
    when 0 then generate_integer(rng)
    when 1 then generate_string(rng)
    when 2 then true
    when 3 then false
    end
  end

  # Generate a signed `Integer` in `[-SCALAR_INTEGER_BOUND, SCALAR_INTEGER_BOUND]`.
  def generate_integer(rng)
    rng.rand(-SCALAR_INTEGER_BOUND..SCALAR_INTEGER_BOUND)
  end

  # Generate a non-empty random alphanumeric `String` between 1
  # and 32 characters long.
  def generate_string(rng)
    length = 1 + rng.rand(32)
    Array.new(length) { SCALAR_STRING_ALPHABET.sample(random: rng) }.join
  end

  # Build a chain of single-key symbol-keyed hashes ending with the
  # leaf value. `path = [:a, :b, :c], leaf = 42` produces
  # `{a: {b: {c: 42}}}`.
  def build_nested_hash(path, leaf_value)
    path.reverse.inject(leaf_value) { |acc, key| {key => acc} }
  end

  # Walk `payload` using the camelCase output path. Every segment
  # is a `Symbol` (hash key); raw-field output paths never include
  # array indices.
  def dig_payload(payload, output_path)
    output_path.inject(payload) do |current, segment|
      break nil unless current.is_a?(Hash)
      current[segment]
    end
  end
end
