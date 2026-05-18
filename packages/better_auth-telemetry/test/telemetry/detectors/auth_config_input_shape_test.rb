# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/env_helpers"
require "better_auth"
require "better_auth/telemetry/detectors/auth_config"
require "better_auth/telemetry/options"

# Verifies the dual-input contract (Requirement 13.1) and the
# context-override pass-through (Requirement 13.9) wired by task
# 4.11:
#
# 1. `AuthConfig.call` accepts both a {BetterAuth::Configuration}
#    and the raw options hash that {BetterAuth::Auth.new} would
#    consume, and produces deep-equal payloads for the same logical
#    configuration.
# 2. When a `context` is supplied (either a {NormalizedContext} or
#    a raw hash), its `:database` and `:adapter` values pass
#    through verbatim into `payload[:database]` and
#    `payload[:adapter]`.
#
# The "deep-equal" assertion uses a logical configuration whose
# leaves match the post-normalization shape produced by
# {BetterAuth::Configuration#initialize}: defaults from
# `DEFAULT_EMAIL_AND_PASSWORD` and `DEFAULT_SESSION` are
# pre-populated, the rate-limit fields are explicitly set so the
# auto-fill branches do not introduce noise, and trusted-origin /
# base-url env vars are cleared via `with_env` so
# `normalize_trusted_origins` cannot inflate the configured array.
class AuthConfigInputShapeTest < Minitest::Test
  AuthConfig = BetterAuth::Telemetry::Detectors::AuthConfig
  NormalizedContext = BetterAuth::Telemetry::NormalizedContext

  include BetterAuth::Telemetry::Test::EnvHelpers

  # Build a logical configuration hash that survives Configuration
  # normalization without changing the leaves the AuthConfig
  # detector reads. Section-by-section notes:
  #
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
  # * `plugins: []` and the empty `social_providers`/`user`/
  #   `verification`/`account` shapes match Configuration's empty
  #   defaults.
  def build_logical_configuration
    {
      secret: "0" * 40,
      database: :memory,
      email_verification: {
        send_verification_email: ->(*) {},
        send_on_sign_up: true,
        expires_in: 3600
      },
      email_and_password: {
        enabled: true,
        min_password_length: 8,
        max_password_length: 128,
        require_email_verification: true,
        password: {hash: ->(*) {}, verify: ->(*) {}}
      },
      session: {
        update_age: 86_400,
        expires_in: 604_800,
        fresh_age: 86_400
      },
      account: {},
      user: {},
      verification: {},
      hooks: {before: ->(*) {}, after: ->(*) {}},
      secondary_storage: "redis-storage",
      advanced: {
        cookie_prefix: "ba",
        use_secure_cookies: true
      },
      trusted_origins: ["https://example.com"],
      rate_limit: {
        enabled: false,
        window: 10,
        max: 100,
        storage: "memory"
      },
      on_api_error: {error_url: "/error", on_error: ->(*) {}, throw: false},
      social_providers: {
        github: {map_profile_to_user: ->(*) {}, scope: ["read"]}
      },
      plugins: [],
      database_hooks: {
        user: {create: {before: ->(*) {}, after: ->(*) {}}},
        session: {},
        account: {},
        verification: {}
      }
    }
  end

  # Clear every env var that
  # `BetterAuth::Configuration#normalize_trusted_origins` and the
  # production-environment toggle in `normalize_rate_limit` would
  # otherwise fold into the normalized config.
  def with_clean_telemetry_env
    with_env(
      "BETTER_AUTH_TRUSTED_ORIGINS" => nil,
      "BETTER_AUTH_URL" => nil,
      "BASE_URL" => nil,
      "BETTER_AUTH_ENV" => nil,
      "RACK_ENV" => nil,
      "RAILS_ENV" => nil,
      "APP_ENV" => nil
    ) do
      yield
    end
  end

  # ------------------------------------------------------------------
  # Dual-input contract: Configuration ≡ raw hash
  # ------------------------------------------------------------------

  def test_payload_top_level_keys_match_between_configuration_and_raw_hash_inputs
    with_clean_telemetry_env do
      h = build_logical_configuration

      payload_from_config = AuthConfig.call(BetterAuth::Configuration.new(h), nil)
      payload_from_hash = AuthConfig.call(h, nil)

      refute_nil payload_from_config
      refute_nil payload_from_hash
      assert_equal payload_from_config.keys.sort, payload_from_hash.keys.sort
    end
  end

  def test_payload_from_configuration_is_deep_equal_to_payload_from_raw_hash
    with_clean_telemetry_env do
      h = build_logical_configuration

      payload_from_config = AuthConfig.call(BetterAuth::Configuration.new(h), nil)
      payload_from_hash = AuthConfig.call(h, nil)

      assert_equal payload_from_config, payload_from_hash
    end
  end

  # Each top-level section is asserted individually so a regression
  # points at the exact section that drifted, not a giant diff. The
  # `database` / `adapter` sections are sourced exclusively from
  # `context` (Requirement 13.9) and so are excluded here — they
  # have their own coverage further down.
  (AuthConfig::TOP_LEVEL_KEYS - %i[database adapter]).each do |section|
    define_method "test_section_#{section}_is_deep_equal_between_configuration_and_raw_hash" do
      with_clean_telemetry_env do
        h = build_logical_configuration

        payload_from_config = AuthConfig.call(BetterAuth::Configuration.new(h), nil)
        payload_from_hash = AuthConfig.call(h, nil)

        actual = payload_from_hash[section]
        expected = payload_from_config[section]
        if expected.nil?
          assert_nil actual,
            "section #{section} differs between Configuration and raw-hash inputs"
        else
          assert_equal expected, actual,
            "section #{section} differs between Configuration and raw-hash inputs"
        end
      end
    end
  end

  # ------------------------------------------------------------------
  # Context override pass-through
  # ------------------------------------------------------------------

  def test_context_override_database_and_adapter_pass_through_via_normalized_context
    with_clean_telemetry_env do
      h = build_logical_configuration
      context = NormalizedContext.from(database: "custom-db", adapter: "MyAdapter")

      payload = AuthConfig.call(BetterAuth::Configuration.new(h), context)

      assert_equal "custom-db", payload[:database]
      assert_equal "MyAdapter", payload[:adapter]
    end
  end

  def test_context_override_database_and_adapter_pass_through_for_raw_hash_options
    with_clean_telemetry_env do
      h = build_logical_configuration
      context = NormalizedContext.from(database: "raw-db", adapter: "RawAdapter")

      payload = AuthConfig.call(h, context)

      assert_equal "raw-db", payload[:database]
      assert_equal "RawAdapter", payload[:adapter]
    end
  end

  def test_context_override_accepts_a_raw_hash_with_symbol_keys
    h = build_logical_configuration
    payload = AuthConfig.call(h, {database: "sym-db", adapter: "SymAdapter"})

    assert_equal "sym-db", payload[:database]
    assert_equal "SymAdapter", payload[:adapter]
  end

  def test_context_override_accepts_a_raw_hash_with_string_keys
    h = build_logical_configuration
    payload = AuthConfig.call(h, {"database" => "string-db", "adapter" => "StringAdapter"})

    assert_equal "string-db", payload[:database]
    assert_equal "StringAdapter", payload[:adapter]
  end

  def test_database_and_adapter_are_nil_when_context_is_nil
    payload = AuthConfig.call(build_logical_configuration, nil)

    assert_nil payload[:database]
    assert_nil payload[:adapter]
  end

  def test_database_and_adapter_are_nil_when_normalized_context_is_empty
    payload = AuthConfig.call(build_logical_configuration, NormalizedContext.from({}))

    assert_nil payload[:database]
    assert_nil payload[:adapter]
  end

  def test_database_and_adapter_are_nil_when_raw_hash_context_lacks_those_keys
    payload = AuthConfig.call(build_logical_configuration, {custom_track: ->(*) {}})

    assert_nil payload[:database]
    assert_nil payload[:adapter]
  end

  # The override is a raw pass-through, NOT a redaction. A
  # falsey-but-present value (e.g. `false`) must surface verbatim,
  # otherwise consumers cannot distinguish "explicitly set to false"
  # from "not configured".
  def test_context_override_is_a_raw_pass_through_for_falsey_values
    h = build_logical_configuration
    payload = AuthConfig.call(h, NormalizedContext.from(database: false, adapter: false))

    assert_equal false, payload[:database]
    assert_equal false, payload[:adapter]
  end
end
