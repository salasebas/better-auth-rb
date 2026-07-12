# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/env_helpers"
require "json"
require "better_auth"
require "better_auth/telemetry/detectors/auth_config"

# Verifies the redaction map rows under `advanced.*`,
# `trustedOrigins`, `rateLimit.*`, `onAPIError.*`, `logger.*`,
# `secondaryStorage`, and the full `databaseHooks.*` 4 × 2 × 2 tree
# filled in by task 4.10.
#
# The strategy: build a `BetterAuth::Configuration` with **every**
# redacted advanced/cookies/databaseHooks leaf set to a unique
# sentinel string, every raw scalar set to a unique integer, and
# then assert:
#
#   * each documented `bool` leaf collapses to a strict `true`/`false`,
#   * each documented `raw` leaf carries its sentinel verbatim,
#   * `trustedOrigins` is the integer count of the configured list
#     (3, for an array of 3),
#   * `secondaryStorage` flips between `true` and `false`,
#   * `JSON.generate(payload)` never contains any redacted sentinel
#     string — including the `secret`, the literal `cookiePrefix`,
#     or any cross-subdomain / cookie-attributes `domain` value.
class AuthConfigAdvancedTest < Minitest::Test
  AuthConfig = BetterAuth::Telemetry::Detectors::AuthConfig

  include BetterAuth::Telemetry::Test::EnvHelpers

  # Sentinel strings for redacted leaves. Every value is unique so a
  # leak of any one leaf into the JSON payload is immediately
  # attributable to that leaf.
  REDACTED_SENTINELS = {
    secret: "SENTINEL_secret_should_never_leak",
    cookie_prefix: "SENTINEL_cookie_prefix_should_never_leak",
    cookies: "SENTINEL_cookies_object_should_never_leak",
    cross_sub_domain_cookies_domain: "SENTINEL_cross_sub_domain_domain_should_never_leak",
    default_cookie_attributes_domain: "SENTINEL_default_cookie_attributes_domain_should_never_leak",
    rate_limit_custom_storage: "SENTINEL_rate_limit_custom_storage_should_never_leak",
    on_api_error_on_error: "SENTINEL_on_api_error_on_error_should_never_leak",
    logger_log: "SENTINEL_logger_log_should_never_leak",
    secondary_storage: "SENTINEL_secondary_storage_should_never_leak"
  }.freeze

  # Per-leaf sentinels for the 16-leaf databaseHooks tree. The keys
  # use `model_operation_phase` so failures point at the exact tree
  # coordinate.
  DATABASE_HOOK_SENTINELS = AuthConfig::DATABASE_HOOK_MODELS.flat_map do |model|
    AuthConfig::DATABASE_HOOK_OPERATIONS.flat_map do |operation|
      AuthConfig::DATABASE_HOOK_PHASES.map do |phase|
        [
          [model, operation, phase],
          "SENTINEL_database_hooks_#{model}_#{operation}_#{phase}_should_never_leak"
        ]
      end
    end
  end.to_h.freeze

  # Raw integer sentinels. Each integer is unique so the assertions
  # also confirm the right scalar lands at the right key.
  RAW_SENTINELS = {
    cross_sub_domain_enabled: 11_001,
    cross_sub_domain_additional: 11_002,
    advanced_database_generate_id: 11_003,
    advanced_database_default_find_many_limit: 11_004,
    advanced_use_secure_cookies: 11_005,
    ip_address_disable_ip_tracking: 11_006,
    ip_address_ip_address_headers: 11_007,
    advanced_disable_csrf_check: 11_008,
    cookie_attributes_expires: 11_009,
    cookie_attributes_secure: 11_010,
    cookie_attributes_same_site: 11_011,
    cookie_attributes_path: 11_012,
    cookie_attributes_http_only: 11_013,
    rate_limit_storage: 22_001,
    rate_limit_model_name: 22_002,
    rate_limit_window: 22_003,
    rate_limit_enabled: 22_004,
    rate_limit_max: 22_005,
    on_api_error_error_url: 33_001,
    on_api_error_throw: 33_002,
    logger_disabled: 44_001,
    logger_level: 44_002
  }.freeze

  TRUSTED_ORIGINS = ["https://auth.example.com", "b", "c"].freeze

  # Build the full sentinel-laden configuration. Wrapping the
  # constructor in `with_env` ensures the `BETTER_AUTH_TRUSTED_ORIGINS`
  # env list cannot inflate the configured `trusted_origins` array
  # behind our back (Configuration#normalize_trusted_origins folds
  # the env list in unconditionally).
  def configuration
    with_env(
      "BETTER_AUTH_TRUSTED_ORIGINS" => nil,
      "BETTER_AUTH_URL" => nil,
      "BASE_URL" => nil
    ) do
      BetterAuth::Configuration.new(
        secret: REDACTED_SENTINELS[:secret],
        base_url: "https://auth.example.com",
        secondary_storage: REDACTED_SENTINELS[:secondary_storage],
        trusted_origins: TRUSTED_ORIGINS.dup,
        advanced: {
          cookie_prefix: REDACTED_SENTINELS[:cookie_prefix],
          cookies: REDACTED_SENTINELS[:cookies],
          cross_sub_domain_cookies: {
            domain: REDACTED_SENTINELS[:cross_sub_domain_cookies_domain],
            enabled: RAW_SENTINELS[:cross_sub_domain_enabled],
            additional_cookies: RAW_SENTINELS[:cross_sub_domain_additional]
          },
          database: {
            generate_id: RAW_SENTINELS[:advanced_database_generate_id],
            default_find_many_limit: RAW_SENTINELS[:advanced_database_default_find_many_limit]
          },
          use_secure_cookies: RAW_SENTINELS[:advanced_use_secure_cookies],
          ip_address: {
            disable_ip_tracking: RAW_SENTINELS[:ip_address_disable_ip_tracking],
            ip_address_headers: RAW_SENTINELS[:ip_address_ip_address_headers]
          },
          disable_csrf_check: RAW_SENTINELS[:advanced_disable_csrf_check],
          default_cookie_attributes: {
            expires: RAW_SENTINELS[:cookie_attributes_expires],
            secure: RAW_SENTINELS[:cookie_attributes_secure],
            same_site: RAW_SENTINELS[:cookie_attributes_same_site],
            domain: REDACTED_SENTINELS[:default_cookie_attributes_domain],
            path: RAW_SENTINELS[:cookie_attributes_path],
            http_only: RAW_SENTINELS[:cookie_attributes_http_only]
          }
        },
        rate_limit: {
          storage: RAW_SENTINELS[:rate_limit_storage],
          model_name: RAW_SENTINELS[:rate_limit_model_name],
          window: RAW_SENTINELS[:rate_limit_window],
          custom_storage: REDACTED_SENTINELS[:rate_limit_custom_storage],
          enabled: RAW_SENTINELS[:rate_limit_enabled],
          max: RAW_SENTINELS[:rate_limit_max]
        },
        on_api_error: {
          error_url: RAW_SENTINELS[:on_api_error_error_url],
          on_error: REDACTED_SENTINELS[:on_api_error_on_error],
          throw: RAW_SENTINELS[:on_api_error_throw]
        },
        logger: {
          disabled: RAW_SENTINELS[:logger_disabled],
          level: RAW_SENTINELS[:logger_level],
          log: REDACTED_SENTINELS[:logger_log]
        },
        database_hooks: build_database_hooks
      )
    end
  end

  def build_database_hooks
    AuthConfig::DATABASE_HOOK_MODELS.each_with_object({}) do |model, models|
      models[model] = AuthConfig::DATABASE_HOOK_OPERATIONS.each_with_object({}) do |operation, ops|
        ops[operation] = AuthConfig::DATABASE_HOOK_PHASES.each_with_object({}) do |phase, phases|
          phases[phase] = DATABASE_HOOK_SENTINELS[[model, operation, phase]]
        end
      end
    end
  end

  def payload
    @payload ||= AuthConfig.call(configuration, nil)
  end

  # ------------------------------------------------------------------
  # advanced.*
  # ------------------------------------------------------------------

  def test_advanced_section_exposes_documented_camelcase_keys
    assert_equal(
      %i[cookiePrefix cookies crossSubDomainCookies database useSecureCookies ipAddress disableCSRFCheck cookieAttributes].sort,
      payload[:advanced].keys.sort
    )
  end

  def test_advanced_redacted_leaves_collapse_to_strict_true
    advanced = payload[:advanced]

    assert_equal true, advanced[:cookiePrefix]
    assert_equal true, advanced[:cookies]
    assert_equal true, advanced[:crossSubDomainCookies][:domain]
    assert_equal true, advanced[:cookieAttributes][:domain]
  end

  def test_advanced_redacted_leaves_collapse_to_strict_false_when_unset
    config = BetterAuth::Configuration.new(secret: "0" * 40)
    advanced = AuthConfig.call(config, nil)[:advanced]

    assert_equal false, advanced[:cookiePrefix]
    assert_equal false, advanced[:cookies]
    assert_equal false, advanced[:crossSubDomainCookies][:domain]
    assert_equal false, advanced[:cookieAttributes][:domain]
  end

  def test_advanced_raw_scalars_pass_through_verbatim
    advanced = payload[:advanced]

    assert_equal RAW_SENTINELS[:cross_sub_domain_enabled], advanced[:crossSubDomainCookies][:enabled]
    assert_equal RAW_SENTINELS[:cross_sub_domain_additional], advanced[:crossSubDomainCookies][:additionalCookies]
    assert_equal true, advanced[:database][:generateId]
    assert_equal RAW_SENTINELS[:advanced_database_default_find_many_limit], advanced[:database][:defaultFindManyLimit]
    assert_equal RAW_SENTINELS[:advanced_use_secure_cookies], advanced[:useSecureCookies]
    assert_equal RAW_SENTINELS[:ip_address_disable_ip_tracking], advanced[:ipAddress][:disableIpTracking]
    assert_equal RAW_SENTINELS[:ip_address_ip_address_headers], advanced[:ipAddress][:ipAddressHeaders]
    assert_equal RAW_SENTINELS[:advanced_disable_csrf_check], advanced[:disableCSRFCheck]
  end

  def test_advanced_cookie_attributes_renames_default_cookie_attributes_to_cookieAttributes
    cookie_attrs = payload[:advanced][:cookieAttributes]

    assert_equal RAW_SENTINELS[:cookie_attributes_expires], cookie_attrs[:expires]
    assert_equal RAW_SENTINELS[:cookie_attributes_secure], cookie_attrs[:secure]
    assert_equal RAW_SENTINELS[:cookie_attributes_same_site], cookie_attrs[:sameSite]
    assert_equal RAW_SENTINELS[:cookie_attributes_path], cookie_attrs[:path]
    assert_equal RAW_SENTINELS[:cookie_attributes_http_only], cookie_attrs[:httpOnly]
  end

  # ------------------------------------------------------------------
  # trustedOrigins
  # ------------------------------------------------------------------

  def test_trusted_origins_emits_integer_count
    assert_equal TRUSTED_ORIGINS.length, payload[:trustedOrigins]
  end

  def test_trusted_origins_contains_required_canonical_origin_when_no_extras_are_configured
    with_env(
      "BETTER_AUTH_TRUSTED_ORIGINS" => nil,
      "BETTER_AUTH_URL" => nil,
      "BASE_URL" => nil
    ) do
      config = BetterAuth::Configuration.new(secret: "0" * 40, base_url: "https://auth.example.com")
      assert_equal 1, AuthConfig.call(config, nil)[:trustedOrigins]
    end
  end

  def test_trusted_origins_is_nil_for_raw_hash_without_the_key
    raw_hash = {secret: "0" * 40}

    assert_nil AuthConfig.call(raw_hash, nil)[:trustedOrigins]
  end

  # ------------------------------------------------------------------
  # rateLimit.*
  # ------------------------------------------------------------------

  def test_rate_limit_section_carries_documented_camelcase_keys
    rate_limit = payload[:rateLimit]

    assert_equal RAW_SENTINELS[:rate_limit_storage], rate_limit[:storage]
    assert_equal RAW_SENTINELS[:rate_limit_model_name], rate_limit[:modelName]
    assert_equal RAW_SENTINELS[:rate_limit_window], rate_limit[:window]
    assert_equal true, rate_limit[:customStorage]
    assert_equal RAW_SENTINELS[:rate_limit_enabled], rate_limit[:enabled]
    assert_equal RAW_SENTINELS[:rate_limit_max], rate_limit[:max]
  end

  def test_rate_limit_custom_storage_is_strict_false_when_unset
    config = BetterAuth::Configuration.new(secret: "0" * 40)

    assert_equal false, AuthConfig.call(config, nil)[:rateLimit][:customStorage]
  end

  # ------------------------------------------------------------------
  # onAPIError.*
  # ------------------------------------------------------------------

  def test_on_api_error_section_carries_documented_camelcase_keys
    section = payload[:onAPIError]

    assert_equal true, section[:errorURL]
    assert_equal true, section[:onError]
    assert_equal RAW_SENTINELS[:on_api_error_throw], section[:throw]
  end

  def test_on_api_error_on_error_is_strict_false_when_unset
    config = BetterAuth::Configuration.new(secret: "0" * 40)

    assert_equal false, AuthConfig.call(config, nil)[:onAPIError][:onError]
  end

  # ------------------------------------------------------------------
  # logger.*
  # ------------------------------------------------------------------

  def test_logger_section_carries_documented_camelcase_keys
    section = payload[:logger]

    assert_equal RAW_SENTINELS[:logger_disabled], section[:disabled]
    assert_equal RAW_SENTINELS[:logger_level], section[:level]
    assert_equal true, section[:log]
  end

  def test_logger_log_is_strict_false_when_unset
    config = BetterAuth::Configuration.new(secret: "0" * 40)

    assert_equal false, AuthConfig.call(config, nil)[:logger][:log]
  end

  # ------------------------------------------------------------------
  # secondaryStorage
  # ------------------------------------------------------------------

  def test_secondary_storage_is_true_when_configured
    assert_equal true, payload[:secondaryStorage]
  end

  def test_secondary_storage_is_false_when_nil
    config = BetterAuth::Configuration.new(secret: "0" * 40)

    assert_equal false, AuthConfig.call(config, nil)[:secondaryStorage]
  end

  # ------------------------------------------------------------------
  # databaseHooks.*
  # ------------------------------------------------------------------

  def test_database_hooks_emits_full_4_by_2_by_2_tree
    hooks = payload[:databaseHooks]

    assert_equal AuthConfig::DATABASE_HOOK_MODELS.sort, hooks.keys.sort

    AuthConfig::DATABASE_HOOK_MODELS.each do |model|
      assert_equal AuthConfig::DATABASE_HOOK_OPERATIONS.sort, hooks[model].keys.sort
      AuthConfig::DATABASE_HOOK_OPERATIONS.each do |operation|
        assert_equal AuthConfig::DATABASE_HOOK_PHASES.sort, hooks[model][operation].keys.sort
      end
    end
  end

  def test_database_hooks_redacts_every_leaf_to_strict_true
    hooks = payload[:databaseHooks]

    AuthConfig::DATABASE_HOOK_MODELS.each do |model|
      AuthConfig::DATABASE_HOOK_OPERATIONS.each do |operation|
        AuthConfig::DATABASE_HOOK_PHASES.each do |phase|
          leaf = hooks.dig(model, operation, phase)
          assert_equal true, leaf,
            "databaseHooks.#{model}.#{operation}.#{phase} should be strict true"
        end
      end
    end
  end

  def test_database_hooks_collapses_to_strict_false_when_unset
    config = BetterAuth::Configuration.new(secret: "0" * 40)
    hooks = AuthConfig.call(config, nil)[:databaseHooks]

    AuthConfig::DATABASE_HOOK_MODELS.each do |model|
      AuthConfig::DATABASE_HOOK_OPERATIONS.each do |operation|
        AuthConfig::DATABASE_HOOK_PHASES.each do |phase|
          leaf = hooks.dig(model, operation, phase)
          assert_equal false, leaf,
            "databaseHooks.#{model}.#{operation}.#{phase} should be strict false when unset"
        end
      end
    end
  end

  # ------------------------------------------------------------------
  # JSON round-trip: redacted sentinels (including secret + cookie
  # prefix + every host-identifying domain) must not leak.
  # ------------------------------------------------------------------

  def test_json_generate_payload_contains_no_redacted_sentinel_strings
    json = JSON.generate(payload)

    REDACTED_SENTINELS.each do |label, sentinel|
      refute_includes json, sentinel,
        "redacted sentinel for #{label.inspect} (#{sentinel.inspect}) leaked into JSON payload"
    end

    DATABASE_HOOK_SENTINELS.each do |coords, sentinel|
      refute_includes json, sentinel,
        "redacted databaseHooks sentinel at #{coords.inspect} (#{sentinel.inspect}) leaked into JSON payload"
    end
  end

  def test_json_generate_payload_contains_raw_scalars
    json = JSON.generate(payload)

    RAW_SENTINELS.except(:advanced_database_generate_id, :on_api_error_error_url).each do |label, sentinel|
      assert_includes json, sentinel.to_s,
        "raw sentinel #{label.inspect} (#{sentinel.inspect}) should appear in JSON payload"
    end
  end
end
