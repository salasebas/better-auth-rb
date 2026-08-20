# frozen_string_literal: true

require "openssl"
require_relative "../../test_helper"

class BetterAuthPluginsHaveIBeenPwnedTest < Minitest::Test
  SECRET = "phase-nine-hibp-secret-with-enough-entropy"

  def test_prevents_sign_up_with_compromised_password
    auth = build_auth(compromised_passwords: ["123456789"])

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {email: "pwned@example.com", password: "123456789", name: "Pwned"})
    end

    assert_equal 400, error.status_code
    assert_equal "PASSWORD_COMPROMISED", error.code
    assert_nil auth.context.internal_adapter.find_user_by_email("pwned@example.com")
  end

  def test_allows_uncompromised_password_and_rejects_change_password
    auth = build_auth(compromised_passwords: ["new-pwned-password"])
    cookie = sign_up_cookie(auth, email: "safe@example.com", password: "safe-password123")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.change_password(
        headers: {"cookie" => cookie},
        body: {currentPassword: "safe-password123", newPassword: "new-pwned-password"}
      )
    end
    assert_equal 400, error.status_code
    assert_equal "PASSWORD_COMPROMISED", error.code
  end

  def test_custom_paths_and_message
    calls = []
    auth = BetterAuth.auth(
      secret: SECRET,
      email_and_password: {enabled: true},
      plugins: [
        BetterAuth::Plugins.have_i_been_pwned(
          paths: ["/change-password"],
          custom_password_compromised_message: "Pick a safer password",
          range_lookup: ->(prefix) {
            calls << prefix
            suffix_for("123456789")
          }
        )
      ]
    )

    auth.api.sign_up_email(body: {email: "custom-hibp@example.com", password: "123456789", name: "HIBP"})
    assert_empty calls

    cookie = sign_in_cookie(auth, email: "custom-hibp@example.com", password: "123456789")
    error = assert_raises(BetterAuth::APIError) do
      auth.api.change_password(headers: {"cookie" => cookie}, body: {currentPassword: "123456789", newPassword: "123456789"})
    end
    assert_equal "Pick a safer password", error.message
  end

  def test_disabled_option_skips_password_check
    calls = []
    auth = BetterAuth.auth(
      secret: SECRET,
      email_and_password: {enabled: true},
      plugins: [
        BetterAuth::Plugins.have_i_been_pwned(
          enabled: false,
          range_lookup: ->(prefix) {
            calls << prefix
            suffix_for("123456789")
          }
        )
      ]
    )

    result = auth.api.sign_up_email(body: {email: "disabled-hibp@example.com", password: "123456789", name: "HIBP"})

    assert result[:user]
    assert_empty calls
  end

  def test_plugin_id_matches_upstream
    plugin = BetterAuth::Plugins.have_i_been_pwned

    assert_equal "have-i-been-pwned", plugin.id
  end

  def test_default_paths_match_upstream
    plugin = BetterAuth::Plugins.have_i_been_pwned

    assert_equal [
      "/sign-up/email",
      "/change-password",
      "/reset-password",
      "/email-otp/reset-password",
      "/phone-number/reset-password",
      "/admin/create-user",
      "/admin/set-user-password"
    ], plugin.options[:paths]
  end

  def test_explicit_empty_paths_disable_password_checks
    calls = []
    auth = BetterAuth.auth(
      secret: SECRET,
      email_and_password: {enabled: true},
      plugins: [
        BetterAuth::Plugins.have_i_been_pwned(
          paths: [],
          range_lookup: ->(prefix) {
            calls << prefix
            suffix_for("123456789")
          }
        )
      ]
    )

    result = auth.api.sign_up_email(body: {email: "empty-paths@example.com", password: "123456789", name: "HIBP"})

    assert result[:user]
    assert_empty calls
  end

  def test_default_paths_reject_email_otp_password_reset
    sent = []
    auth = build_auth_with_plugins(
      compromised_password: "email-otp-compromised",
      plugins: [
        BetterAuth::Plugins.email_otp(send_verification_otp: ->(data, _ctx = nil) { sent << data })
      ]
    )
    auth.api.sign_up_email(body: {email: "hibp-email-otp@example.com", password: "safe-password123", name: "HIBP"})
    auth.api.request_password_reset_email_otp(body: {email: "hibp-email-otp@example.com"})

    error = assert_raises(BetterAuth::APIError) do
      auth.api.reset_password_email_otp(
        body: {email: "hibp-email-otp@example.com", otp: sent.first[:otp], password: "email-otp-compromised"}
      )
    end

    assert_equal 400, error.status_code
    assert_equal "PASSWORD_COMPROMISED", error.code
  end

  def test_default_paths_reject_phone_number_password_reset
    reset_sent = []
    auth = build_auth_with_plugins(
      compromised_password: "phone-reset-compromised",
      plugins: [
        BetterAuth::Plugins.phone_number(
          send_otp: ->(*) {},
          send_password_reset_otp: ->(data, _ctx = nil) { reset_sent << data }
        )
      ]
    )
    auth.api.sign_up_email(body: {email: "hibp-phone@example.com", password: "safe-password123", name: "HIBP"})
    user = auth.context.internal_adapter.find_user_by_email("hibp-phone@example.com")[:user]
    auth.context.internal_adapter.update_user(user["id"], phoneNumber: "+15105550183", phoneNumberVerified: true)
    auth.api.request_password_reset_phone_number(body: {phoneNumber: "+15105550183"})

    error = assert_raises(BetterAuth::APIError) do
      auth.api.reset_password_phone_number(
        body: {phoneNumber: "+15105550183", otp: reset_sent.first[:code], newPassword: "phone-reset-compromised"}
      )
    end

    assert_equal 400, error.status_code
    assert_equal "PASSWORD_COMPROMISED", error.code
  end

  def test_default_paths_reject_admin_password_endpoints
    auth = build_auth_with_plugins(
      compromised_password: "admin-compromised",
      plugins: [BetterAuth::Plugins.admin]
    )
    admin_cookie = sign_up_cookie(auth, email: "hibp-admin@example.com", password: "safe-password123")
    admin = auth.api.get_session(headers: {"cookie" => admin_cookie})[:user]
    auth.context.internal_adapter.update_user(admin["id"], role: "admin")

    create_error = assert_raises(BetterAuth::APIError) do
      auth.api.create_user(
        headers: {"cookie" => admin_cookie},
        body: {email: "hibp-created@example.com", password: "admin-compromised", name: "Created"}
      )
    end
    assert_equal 400, create_error.status_code
    assert_equal "PASSWORD_COMPROMISED", create_error.code

    target = auth.api.create_user(
      headers: {"cookie" => admin_cookie},
      body: {email: "hibp-target@example.com", password: "safe-password123", name: "Target"}
    )[:user]
    set_error = assert_raises(BetterAuth::APIError) do
      auth.api.set_user_password(
        headers: {"cookie" => admin_cookie},
        body: {userId: target["id"], newPassword: "admin-compromised"}
      )
    end
    assert_equal 400, set_error.status_code
    assert_equal "PASSWORD_COMPROMISED", set_error.code
  end

  def test_reset_password_invalid_token_does_not_check_hibp
    calls = []
    auth = BetterAuth.auth(
      secret: SECRET,
      email_and_password: {enabled: true},
      plugins: [
        BetterAuth::Plugins.have_i_been_pwned(
          range_lookup: ->(prefix) {
            calls << prefix
            suffix_for("123456789")
          }
        )
      ]
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.reset_password(body: {token: "invalid", newPassword: "123456789"})
    end

    assert_equal 400, error.status_code
    assert_equal BetterAuth::BASE_ERROR_CODES["INVALID_TOKEN"], error.message
    assert_empty calls
  end

  def test_reset_password_valid_token_checks_new_password
    auth = build_auth(compromised_passwords: ["123456789"])
    auth.api.sign_up_email(body: {email: "reset-hibp@example.com", password: "safe-password123", name: "HIBP"})
    user = auth.context.internal_adapter.find_user_by_email("reset-hibp@example.com")[:user]
    auth.context.internal_adapter.create_verification_value(
      identifier: "reset-password:valid-token",
      value: user["id"],
      expiresAt: Time.now + 60
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.reset_password(body: {token: "valid-token", newPassword: "123456789"})
    end

    assert_equal 400, error.status_code
    assert_equal "PASSWORD_COMPROMISED", error.code
  end

  def test_range_lookup_receives_prefix_only_and_matches_case_insensitive_suffix
    calls = []
    auth = BetterAuth.auth(
      secret: SECRET,
      email_and_password: {enabled: true},
      plugins: [
        BetterAuth::Plugins.have_i_been_pwned(
          range_lookup: ->(prefix) {
            calls << prefix
            "abc123:1\n#{suffix_for("123456789").downcase}:2"
          }
        )
      ]
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {email: "prefix-only@example.com", password: "123456789", name: "HIBP"})
    end

    assert_equal 400, error.status_code
    assert_equal 5, calls.first.length
    refute_includes calls.first, "123456789"
  end

  def test_lookup_failure_returns_internal_error
    auth = BetterAuth.auth(
      secret: SECRET,
      email_and_password: {enabled: true},
      plugins: [
        BetterAuth::Plugins.have_i_been_pwned(
          range_lookup: ->(_prefix) { raise "lookup failed" }
        )
      ]
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {email: "lookup-fail@example.com", password: "safe-password123", name: "HIBP"})
    end

    assert_equal 500, error.status_code
    assert_equal "Failed to check password. Please try again later.", error.message
  end

  def build_auth(compromised_passwords:)
    compromised = compromised_passwords.map { |password| suffix_for(password) }.join("\n")
    BetterAuth.auth(
      secret: SECRET,
      email_and_password: {enabled: true},
      plugins: [
        BetterAuth::Plugins.have_i_been_pwned(range_lookup: ->(_prefix) { compromised })
      ]
    )
  end

  def build_auth_with_plugins(compromised_password:, plugins:)
    BetterAuth.auth(
      secret: SECRET,
      database: :memory,
      email_and_password: {enabled: true},
      plugins: [
        BetterAuth::Plugins.have_i_been_pwned(
          range_lookup: ->(_prefix) { suffix_for(compromised_password) }
        ),
        *plugins
      ]
    )
  end

  def suffix_for(password)
    OpenSSL::Digest.hexdigest("SHA1", password).upcase[5..]
  end

  def sign_up_cookie(auth, email:, password:)
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: email, password: password, name: "HIBP"},
      as_response: true
    )
    cookie_header(headers.fetch("set-cookie"))
  end

  def sign_in_cookie(auth, email:, password:)
    _status, headers, _body = auth.api.sign_in_email(
      body: {email: email, password: password},
      as_response: true
    )
    cookie_header(headers.fetch("set-cookie"))
  end

  def cookie_header(set_cookie)
    set_cookie.to_s.lines.map { |line| line.split(";").first }.join("; ")
  end
end
