# frozen_string_literal: true

require_relative "../../test_helper"
require "json"
require "better_auth"
require "better_auth/telemetry/detectors/auth_config"

# Verifies the redaction map rows under `emailVerification.*`,
# `emailAndPassword.*` (including the nested `password.{hash,verify}`),
# and `hooks.{before,after}` filled in by task 4.8.
#
# The strategy: build a `BetterAuth::Configuration` with **every**
# listed leaf set to a sentinel value. Callables/secrets get a unique
# string token; raw scalars get a unique integer. We then assert each
# emitted key matches the documented redaction (`bool` → strict
# `true`/`false`, `raw` → identity), and that `JSON.generate` of the
# whole config payload never contains any of the redacted sentinel
# strings.
class AuthConfigEmailTest < Minitest::Test
  AuthConfig = BetterAuth::Telemetry::Detectors::AuthConfig

  # Sentinel strings for the callable leaves. Each value is unique so
  # any leak of one specific leaf into the JSON payload would be
  # immediately attributable to that leaf.
  REDACTED_SENTINELS = {
    send_verification_email: "SENTINEL_send_verification_email",
    send_on_sign_up: "SENTINEL_send_on_sign_up",
    send_on_sign_in: "SENTINEL_send_on_sign_in",
    auto_sign_in_after_verification: "SENTINEL_auto_sign_in_after_verification",
    before_email_verification: "SENTINEL_before_email_verification",
    after_email_verification: "SENTINEL_after_email_verification",
    eap_enabled: "SENTINEL_eap_enabled",
    eap_disable_sign_up: "SENTINEL_eap_disable_sign_up",
    eap_require_email_verification: "SENTINEL_eap_require_email_verification",
    eap_send_reset_password: "SENTINEL_eap_send_reset_password",
    eap_on_password_reset: "SENTINEL_eap_on_password_reset",
    eap_password_hash: "SENTINEL_eap_password_hash",
    eap_password_verify: "SENTINEL_eap_password_verify",
    eap_auto_sign_in: "SENTINEL_eap_auto_sign_in",
    eap_revoke_sessions: "SENTINEL_eap_revoke_sessions_on_password_reset",
    hooks_before: "SENTINEL_hooks_before",
    hooks_after: "SENTINEL_hooks_after"
  }.freeze

  # Raw integer sentinels. Each integer is unique so the assertions
  # also confirm the right scalar lands at the right key.
  RAW_SENTINELS = {
    expires_in: 11_111,
    max_password_length: 22_222,
    min_password_length: 33_333,
    reset_password_token_expires_in: 44_444
  }.freeze

  def configuration
    BetterAuth::Configuration.new(
      secret: "0" * 40,
      email_verification: {
        send_verification_email: REDACTED_SENTINELS[:send_verification_email],
        send_on_sign_up: REDACTED_SENTINELS[:send_on_sign_up],
        send_on_sign_in: REDACTED_SENTINELS[:send_on_sign_in],
        auto_sign_in_after_verification: REDACTED_SENTINELS[:auto_sign_in_after_verification],
        expires_in: RAW_SENTINELS[:expires_in],
        before_email_verification: REDACTED_SENTINELS[:before_email_verification],
        after_email_verification: REDACTED_SENTINELS[:after_email_verification]
      },
      email_and_password: {
        enabled: REDACTED_SENTINELS[:eap_enabled],
        disable_sign_up: REDACTED_SENTINELS[:eap_disable_sign_up],
        require_email_verification: REDACTED_SENTINELS[:eap_require_email_verification],
        max_password_length: RAW_SENTINELS[:max_password_length],
        min_password_length: RAW_SENTINELS[:min_password_length],
        send_reset_password: REDACTED_SENTINELS[:eap_send_reset_password],
        reset_password_token_expires_in: RAW_SENTINELS[:reset_password_token_expires_in],
        on_password_reset: REDACTED_SENTINELS[:eap_on_password_reset],
        password: {
          hash: REDACTED_SENTINELS[:eap_password_hash],
          verify: REDACTED_SENTINELS[:eap_password_verify]
        },
        auto_sign_in: REDACTED_SENTINELS[:eap_auto_sign_in],
        revoke_sessions_on_password_reset: REDACTED_SENTINELS[:eap_revoke_sessions]
      },
      hooks: {
        before: REDACTED_SENTINELS[:hooks_before],
        after: REDACTED_SENTINELS[:hooks_after]
      }
    )
  end

  def payload
    @payload ||= AuthConfig.call(configuration, nil)
  end

  # ------------------------------------------------------------------
  # emailVerification.*
  # ------------------------------------------------------------------

  def test_email_verification_callable_leaves_are_strict_true
    section = payload[:emailVerification]

    assert_equal true, section[:sendVerificationEmail]
    assert_equal true, section[:sendOnSignUp]
    assert_equal true, section[:sendOnSignIn]
    assert_equal true, section[:autoSignInAfterVerification]
    assert_equal true, section[:beforeEmailVerification]
    assert_equal true, section[:afterEmailVerification]
  end

  def test_email_verification_expires_in_is_raw
    assert_equal RAW_SENTINELS[:expires_in], payload[:emailVerification][:expiresIn]
  end

  def test_email_verification_callables_become_false_when_unset
    config = BetterAuth::Configuration.new(secret: "0" * 40)
    section = AuthConfig.call(config, nil)[:emailVerification]

    assert_equal false, section[:sendVerificationEmail]
    assert_equal false, section[:sendOnSignUp]
    assert_equal false, section[:sendOnSignIn]
    assert_equal false, section[:autoSignInAfterVerification]
    assert_equal false, section[:beforeEmailVerification]
    assert_equal false, section[:afterEmailVerification]
    assert_nil section[:expiresIn]
  end

  # ------------------------------------------------------------------
  # emailAndPassword.*
  # ------------------------------------------------------------------

  def test_email_and_password_callable_leaves_are_strict_true
    section = payload[:emailAndPassword]

    assert_equal true, section[:enabled]
    assert_equal true, section[:disableSignUp]
    assert_equal true, section[:requireEmailVerification]
    assert_equal true, section[:sendResetPassword]
    assert_equal true, section[:onPasswordReset]
    assert_equal true, section[:autoSignIn]
    assert_equal true, section[:revokeSessionsOnPasswordReset]
  end

  def test_email_and_password_password_hash_and_verify_are_strict_true
    password_section = payload[:emailAndPassword][:password]

    assert_equal true, password_section[:hash]
    assert_equal true, password_section[:verify]
  end

  def test_email_and_password_raw_scalars_pass_through_verbatim
    section = payload[:emailAndPassword]

    assert_equal RAW_SENTINELS[:max_password_length], section[:maxPasswordLength]
    assert_equal RAW_SENTINELS[:min_password_length], section[:minPasswordLength]
    assert_equal RAW_SENTINELS[:reset_password_token_expires_in], section[:resetPasswordTokenExpiresIn]
  end

  def test_email_and_password_callables_become_false_when_unset
    config = BetterAuth::Configuration.new(secret: "0" * 40)
    section = AuthConfig.call(config, nil)[:emailAndPassword]

    assert_equal false, section[:enabled]
    assert_equal false, section[:disableSignUp]
    assert_equal false, section[:requireEmailVerification]
    assert_equal false, section[:sendResetPassword]
    assert_equal false, section[:onPasswordReset]
    assert_equal false, section[:autoSignIn]
    assert_equal false, section[:revokeSessionsOnPasswordReset]
    assert_equal false, section[:password][:hash]
    assert_equal false, section[:password][:verify]
  end

  # ------------------------------------------------------------------
  # hooks.*
  # ------------------------------------------------------------------

  def test_hooks_before_and_after_are_strict_true_when_configured
    section = payload[:hooks]

    assert_equal true, section[:before]
    assert_equal true, section[:after]
  end

  def test_hooks_before_and_after_are_strict_false_when_unset
    config = BetterAuth::Configuration.new(secret: "0" * 40)
    section = AuthConfig.call(config, nil)[:hooks]

    assert_equal false, section[:before]
    assert_equal false, section[:after]
  end

  def test_hooks_with_array_of_procs_still_redacts_to_true
    config = BetterAuth::Configuration.new(
      secret: "0" * 40,
      hooks: {before: [-> {}, -> {}], after: [-> {}]}
    )
    section = AuthConfig.call(config, nil)[:hooks]

    assert_equal true, section[:before]
    assert_equal true, section[:after]
  end

  # ------------------------------------------------------------------
  # JSON round-trip: redacted sentinels must not leak
  # ------------------------------------------------------------------

  def test_json_generate_payload_contains_no_redacted_sentinel_strings
    json = JSON.generate(payload)

    REDACTED_SENTINELS.each_value do |sentinel|
      refute_includes json, sentinel,
        "redacted sentinel #{sentinel.inspect} leaked into JSON payload"
    end
  end

  def test_json_generate_payload_contains_raw_scalars
    json = JSON.generate(payload)

    RAW_SENTINELS.each_value do |sentinel|
      assert_includes json, sentinel.to_s,
        "raw sentinel #{sentinel.inspect} should appear in JSON payload"
    end
  end
end
