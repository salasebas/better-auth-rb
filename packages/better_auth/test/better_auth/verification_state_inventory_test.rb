# frozen_string_literal: true

require_relative "../test_helper"

class BetterAuthVerificationStateInventoryTest < Minitest::Test
  REPOSITORY_ROOT = File.expand_path("../../../..", __dir__)
  CONSUMERS = {
    "packages/better_auth/lib/better_auth/plugins/magic_link.rb" => ["consume_verification_value(stored_token)"],
    "packages/better_auth/lib/better_auth/routes/password.rb" => ["consume_verification_value(\"reset-password:\#{token}\")"],
    "packages/better_auth/lib/better_auth/routes/user.rb" => ["consume_verification_value(\"delete-account-\#{token}\")"],
    "packages/better_auth/lib/better_auth/routes/email_verification.rb" => ["consume_verification_value(identifier)"],
    "packages/better_auth/lib/better_auth/plugins/one_time_token.rb" => ["consume_verification_value(\"one-time-token:\#{stored_token}\")"],
    "packages/better_auth/lib/better_auth/plugins/siwe.rb" => ["consume_verification_value(siwe_identifier(wallet_address, chain_id))"],
    "packages/better_auth/lib/better_auth/plugins/generic_oauth.rb" => ["consume_verification_value(state)"],
    "packages/better_auth/lib/better_auth/plugins/email_otp.rb" => ["consume_verification_value(identifier)"],
    "packages/better_auth/lib/better_auth/plugins/phone_number.rb" => ["consume_verification_value(identifier)", "Custom verify_otp owns single-use and expiry state completely"],
    "packages/better_auth/lib/better_auth/plugins/two_factor.rb" => ["consume_verification_value(identifier)"],
    "packages/better_auth/lib/better_auth/plugins/device_authorization.rb" => ["adapter.consume_one(", "adapter.increment_one("],
    "packages/better_auth-passkey/lib/better_auth/passkey/challenges.rb" => ["consume_verification_value(verification_token)"],
    "packages/better_auth-passkey/lib/better_auth/passkey/routes/authentication.rb" => ["adapter.increment_one("],
    "packages/better_auth-saml/lib/better_auth/sso/plugin/saml_response.rb" => ["reserve_verification_value("],
    "packages/better_auth-oidc/lib/better_auth/sso/plugin/oidc_runtime.rb" => ["consume_verification_value(identifier)", "sso_restore_oidc_pkce_verifier"],
    "packages/better_auth/lib/better_auth/plugins/oauth_protocol.rb" => ["consume_verification_value(stored_code)", "rescue JSON::ParserError"]
  }.freeze

  REUSABLE_READS = {
    "packages/better_auth/lib/better_auth/routes/password.rb" => ["find_verification_value(\"dummy-verification-token\")", "find_verification_value(\"reset-password:\#{token}\")"],
    "packages/better_auth/lib/better_auth/plugins/email_otp.rb" => ["find_verification_value(email_otp_identifier(email, type))"],
    "packages/better_auth/lib/better_auth/plugins/phone_number.rb" => ["existing = ctx.context.internal_adapter.find_verification_value(identifier)"],
    "packages/better_auth/lib/better_auth/plugins/two_factor.rb" => ["find_verification_value(identifier)"],
    "packages/better_auth-saml/lib/better_auth/sso/plugin/saml_validation_and_state.rb" => ["find_verification_value(\"\#{SSO_SAML_RELAY_STATE_KEY_PREFIX}\#{relay_state}\")"],
    "packages/better_auth-saml/lib/better_auth/sso/plugin/saml_metadata_and_logout.rb" => ["find_verification_value(session_identifier)"]
  }.freeze

  def test_every_verification_state_consumer_uses_its_atomic_or_documented_reusable_pattern
    CONSUMERS.each do |relative_path, patterns|
      source = File.read(File.join(REPOSITORY_ROOT, relative_path))
      patterns.each { |pattern| assert_includes source, pattern, "#{relative_path} lost #{pattern}" }
    end

    REUSABLE_READS.each do |relative_path, patterns|
      source = File.read(File.join(REPOSITORY_ROOT, relative_path))
      patterns.each { |pattern| assert_includes source, pattern, "#{relative_path} lost documented reusable read #{pattern}" }
    end
  end

  def test_legacy_find_then_delete_sequences_are_absent_from_single_use_consumers
    single_use_files = CONSUMERS.keys.grep(%r{packages/better_auth/lib}).reject { |path| path.end_with?("device_authorization.rb", "phone_number.rb", "email_otp.rb", "two_factor.rb") }
    single_use_files.each do |relative_path|
      source = File.read(File.join(REPOSITORY_ROOT, relative_path))
      refute_match(/find_verification_value\([^\n]+\).*?delete_verification_value/m, source, relative_path)
    end
  end
end
