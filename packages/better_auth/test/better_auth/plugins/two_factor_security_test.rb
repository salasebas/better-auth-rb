# frozen_string_literal: true

require_relative "../../test_helper"

class BetterAuthPluginsTwoFactorSecurityTest < Minitest::Test
  SECRET = "two-factor-security-secret-with-enough-entropy"
  PASSWORD = "password123"
  INVALID_TOTP = "not-a-valid-totp"

  def test_totp_budget_spends_five_attempts_then_cancels_the_challenge
    setup = enrolled_auth(email: "totp-cap@example.com")
    challenge = start_challenge(setup)

    BetterAuth::Plugins::DEFAULT_TWO_FACTOR_ALLOWED_ATTEMPTS.times do
      assert_error("UNAUTHORIZED", "INVALID_CODE") { verify_totp(setup, challenge, INVALID_TOTP) }
    end
    assert_error("BAD_REQUEST", "TOO_MANY_ATTEMPTS_REQUEST_NEW_CODE") do
      verify_totp(setup, challenge, current_totp(setup))
    end
    assert_error("UNAUTHORIZED", "INVALID_TWO_FACTOR_COOKIE") do
      verify_totp(setup, challenge, INVALID_TOTP)
    end
  end

  def test_backup_code_budget_spends_five_attempts_then_cancels_the_challenge
    setup = enrolled_auth(email: "backup-cap@example.com")
    challenge = start_challenge(setup)

    BetterAuth::Plugins::DEFAULT_TWO_FACTOR_ALLOWED_ATTEMPTS.times do
      assert_error("UNAUTHORIZED", "INVALID_BACKUP_CODE") { verify_backup(setup, challenge, "invalid-backup") }
    end
    assert_error("BAD_REQUEST", "TOO_MANY_ATTEMPTS_REQUEST_NEW_CODE") do
      verify_backup(setup, challenge, setup.fetch(:backup_codes).first)
    end
    assert_error("UNAUTHORIZED", "INVALID_TWO_FACTOR_COOKIE") do
      verify_backup(setup, challenge, "invalid-backup")
    end
  end

  def test_concurrent_totp_burst_processes_at_most_five_guesses
    setup = enrolled_auth(email: "totp-burst@example.com", account_lockout: {max_failed_attempts: 100})
    challenge = start_challenge(setup)
    ready = Queue.new
    release = Queue.new
    results = Queue.new
    threads = Array.new(20) do
      Thread.new do
        ready << true
        release.pop
        verify_totp(setup, challenge, INVALID_TOTP)
        results << :success
      rescue BetterAuth::APIError => error
        results << [error.status, error.message]
      rescue => error
        results << error
      end
    end
    20.times { ready.pop }
    20.times { release << true }
    threads.each(&:join)
    outcomes = 20.times.map { results.pop }

    refute_includes outcomes, :success
    unexpected = outcomes.grep(Exception)
    assert_empty unexpected, unexpected.map(&:full_message).join("\n")
    processed = outcomes.count { |entry| entry == ["UNAUTHORIZED", error_message("INVALID_CODE")] }
    assert_operator processed, :<=, BetterAuth::Plugins::DEFAULT_TWO_FACTOR_ALLOWED_ATTEMPTS
    assert_operator processed, :>, 0
  end

  def test_internal_totp_error_restores_the_attempt_slot
    setup = enrolled_auth(email: "totp-restore@example.com")
    challenge = start_challenge(setup)

    BetterAuth::Crypto.stub(:symmetric_decrypt, ->(**) { raise "forced decryption failure" }) do
      error = assert_raises(RuntimeError) { verify_totp(setup, challenge, INVALID_TOTP) }
      assert_equal "forced decryption failure", error.message
    end

    verified = verify_totp(setup, challenge, current_totp(setup))
    assert_equal "totp-restore@example.com", verified[:user]["email"]
  end

  def test_account_lock_accumulates_across_totp_otp_and_backup_challenges
    setup = enrolled_auth(email: "cross-factor-lock@example.com", account_lockout: {max_failed_attempts: 3})

    assert_error("UNAUTHORIZED", "INVALID_CODE") do
      verify_totp(setup, start_challenge(setup), INVALID_TOTP)
    end

    otp_challenge = start_challenge(setup)
    setup.fetch(:auth).api.send_two_factor_otp(headers: {"cookie" => otp_challenge})
    assert_error("UNAUTHORIZED", "INVALID_CODE") do
      setup.fetch(:auth).api.verify_two_factor_otp(headers: {"cookie" => otp_challenge}, body: {code: "invalid-otp"})
    end

    assert_error("UNAUTHORIZED", "INVALID_BACKUP_CODE") do
      verify_backup(setup, start_challenge(setup), "invalid-backup")
    end

    assert_error("TOO_MANY_REQUESTS", "ACCOUNT_TEMPORARILY_LOCKED") do
      verify_totp(setup, start_challenge(setup), current_totp(setup))
    end
  end

  def test_success_resets_consecutive_account_failures
    setup = enrolled_auth(email: "lock-reset@example.com", account_lockout: {max_failed_attempts: 3})

    2.times { assert_invalid_totp_on_fresh_challenge(setup) }
    verify_totp(setup, start_challenge(setup), current_totp(setup))
    2.times { assert_invalid_totp_on_fresh_challenge(setup) }
    verified = verify_totp(setup, start_challenge(setup), current_totp(setup))

    assert_equal "lock-reset@example.com", verified[:user]["email"]
    record = two_factor_record(setup)
    assert_equal 0, record["failedVerificationCount"]
    assert_nil record["lockedUntil"]
  end

  def test_elapsed_lock_is_lazily_cleared
    setup = enrolled_auth(email: "elapsed-lock@example.com", account_lockout: {max_failed_attempts: 3})
    3.times { assert_invalid_totp_on_fresh_challenge(setup) }
    assert_error("TOO_MANY_REQUESTS", "ACCOUNT_TEMPORARILY_LOCKED") do
      verify_totp(setup, start_challenge(setup), current_totp(setup))
    end

    update_two_factor(setup, lockedUntil: Time.now - 1)
    verified = verify_totp(setup, start_challenge(setup), current_totp(setup))

    assert_equal "elapsed-lock@example.com", verified[:user]["email"]
    record = two_factor_record(setup)
    assert_equal 0, record["failedVerificationCount"]
    assert_nil record["lockedUntil"]
  end

  def test_disabling_account_lockout_keeps_the_per_challenge_budget
    setup = enrolled_auth(email: "lock-disabled@example.com", account_lockout: {enabled: false, max_failed_attempts: 1})
    challenge = start_challenge(setup)
    BetterAuth::Plugins::DEFAULT_TWO_FACTOR_ALLOWED_ATTEMPTS.times do
      assert_error("UNAUTHORIZED", "INVALID_CODE") { verify_totp(setup, challenge, INVALID_TOTP) }
    end
    assert_error("BAD_REQUEST", "TOO_MANY_ATTEMPTS_REQUEST_NEW_CODE") do
      verify_totp(setup, challenge, current_totp(setup))
    end

    verified = verify_totp(setup, start_challenge(setup), current_totp(setup))
    assert_equal "lock-disabled@example.com", verified[:user]["email"]
    assert_equal 0, two_factor_record(setup)["failedVerificationCount"]
  end

  def test_nil_and_missing_legacy_failure_counts_start_at_one
    setup = enrolled_auth(email: "legacy-counter@example.com", account_lockout: {max_failed_attempts: 10})

    update_two_factor(setup, failedVerificationCount: nil)
    assert_invalid_totp_on_fresh_challenge(setup)
    assert_equal 1, two_factor_record(setup)["failedVerificationCount"]

    stored_record(setup).delete("failedVerificationCount")
    stored_record(setup).delete("lockedUntil")
    assert_invalid_totp_on_fresh_challenge(setup)
    assert_equal 1, two_factor_record(setup)["failedVerificationCount"]
  end

  def test_concurrent_failures_across_challenges_lose_no_updates
    setup = enrolled_auth(email: "concurrent-account-counter@example.com", account_lockout: {max_failed_attempts: 100})
    challenges = Array.new(10) { start_challenge(setup) }
    ready = Queue.new
    release = Queue.new
    results = Queue.new
    threads = challenges.map do |challenge|
      Thread.new do
        ready << true
        release.pop
        verify_totp(setup, challenge, INVALID_TOTP)
        results << :success
      rescue BetterAuth::APIError => error
        results << error
      end
    end
    challenges.length.times { ready.pop }
    challenges.length.times { release << true }
    threads.each(&:join)
    outcomes = challenges.length.times.map { results.pop }

    assert outcomes.all? { |entry| entry.is_a?(BetterAuth::APIError) && entry.message == error_message("INVALID_CODE") }
    assert_equal challenges.length, two_factor_record(setup)["failedVerificationCount"]
  end

  def test_authenticated_enrollment_and_reverification_ignore_an_active_lock
    setup = enrolled_auth(email: "authenticated-exemption@example.com", account_lockout: {max_failed_attempts: 1})
    update_two_factor(setup, failedVerificationCount: 1, lockedUntil: Time.now + 600)

    assert_error("TOO_MANY_REQUESTS", "ACCOUNT_TEMPORARILY_LOCKED") do
      verify_totp(setup, start_challenge(setup), current_totp(setup))
    end

    reverified = setup.fetch(:auth).api.verify_totp(
      headers: {"cookie" => setup.fetch(:session_cookie)},
      body: {code: current_totp(setup)}
    )
    assert_equal "authenticated-exemption@example.com", reverified[:user]["email"]
    assert_equal 1, two_factor_record(setup)["failedVerificationCount"]

    enrollment = setup.fetch(:auth).api.enable_two_factor(
      headers: {"cookie" => setup.fetch(:session_cookie)},
      body: {password: PASSWORD}
    )
    record = two_factor_record(setup)
    setup[:secret] = BetterAuth::Crypto.symmetric_decrypt(key: SECRET, data: record.fetch("secret"))
    enrolled = setup.fetch(:auth).api.verify_totp(
      headers: {"cookie" => setup.fetch(:session_cookie)},
      body: {code: current_totp(setup)}
    )
    assert_equal 10, enrollment[:backupCodes].length
    assert_equal "authenticated-exemption@example.com", enrolled[:user]["email"]
  end

  def test_lock_fields_are_hidden_from_output_and_missing_legacy_lock_is_usable
    setup = enrolled_auth(email: "lock-output@example.com")
    record = two_factor_record(setup)
    output = BetterAuth::Schema.parse_output(setup.fetch(:auth).context.options, "twoFactor", record)

    refute output.key?("failedVerificationCount")
    refute output.key?("lockedUntil")

    stored_record(setup).delete("failedVerificationCount")
    stored_record(setup).delete("lockedUntil")
    verified = verify_totp(setup, start_challenge(setup), current_totp(setup))
    assert_equal "lock-output@example.com", verified[:user]["email"]
  end

  private

  def enrolled_auth(email:, account_lockout: nil)
    sent = []
    plugin_options = {otp_options: {send_otp: ->(data, _ctx = nil) { sent << data }}}
    plugin_options[:account_lockout] = account_lockout if account_lockout
    auth = BetterAuth.auth(
      secret: SECRET,
      plugins: [BetterAuth::Plugins.two_factor(**plugin_options)],
      email_and_password: {enabled: true}
    )
    cookie = sign_up_cookie(auth, email)
    enrollment = auth.api.enable_two_factor(headers: {"cookie" => cookie}, body: {password: PASSWORD})
    record = auth.context.adapter.find_one(model: "twoFactor", where: [{field: "userId", value: user_id_from_email(auth, email)}])
    secret = BetterAuth::Crypto.symmetric_decrypt(key: SECRET, data: record.fetch("secret"))
    verified = auth.api.verify_totp(
      headers: {"cookie" => cookie},
      body: {code: BetterAuth::Plugins.two_factor_totp(secret)},
      return_headers: true
    )
    {
      auth: auth,
      email: email,
      secret: secret,
      backup_codes: enrollment[:backupCodes],
      sent: sent,
      session_cookie: cookie_header(verified.fetch(:headers).fetch("set-cookie"))
    }
  end

  def sign_up_cookie(auth, email)
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: email, password: PASSWORD, name: "Security Test"},
      as_response: true
    )
    cookie_header(headers.fetch("set-cookie"))
  end

  def start_challenge(setup)
    result = setup.fetch(:auth).api.sign_in_email(
      body: {email: setup.fetch(:email), password: PASSWORD},
      return_headers: true
    )
    cookie_header(result.fetch(:headers).fetch("set-cookie"))
  end

  def verify_totp(setup, challenge, code)
    setup.fetch(:auth).api.verify_totp(headers: {"cookie" => challenge}, body: {code: code})
  end

  def verify_backup(setup, challenge, code)
    setup.fetch(:auth).api.verify_backup_code(headers: {"cookie" => challenge}, body: {code: code})
  end

  def current_totp(setup)
    BetterAuth::Plugins.two_factor_totp(setup.fetch(:secret))
  end

  def assert_invalid_totp_on_fresh_challenge(setup)
    assert_error("UNAUTHORIZED", "INVALID_CODE") do
      verify_totp(setup, start_challenge(setup), INVALID_TOTP)
    end
  end

  def assert_error(status, key)
    error = assert_raises(BetterAuth::APIError) { yield }
    assert_equal status, error.status
    assert_equal error_message(key), error.message
    error
  end

  def error_message(key)
    BetterAuth::Plugins::TWO_FACTOR_ERROR_CODES.fetch(key)
  end

  def two_factor_record(setup)
    setup.fetch(:auth).context.adapter.find_one(
      model: "twoFactor",
      where: [{field: "userId", value: user_id_from_email(setup.fetch(:auth), setup.fetch(:email))}]
    )
  end

  def update_two_factor(setup, update)
    record = two_factor_record(setup)
    setup.fetch(:auth).context.adapter.update(
      model: "twoFactor",
      where: [{field: "id", value: record.fetch("id")}],
      update: update
    )
  end

  def stored_record(setup)
    id = two_factor_record(setup).fetch("id")
    setup.fetch(:auth).context.adapter.db.fetch("twoFactor").find { |record| record["id"] == id }
  end

  def user_id_from_email(auth, email)
    auth.context.adapter.find_one(model: "user", where: [{field: "email", value: email}]).fetch("id")
  end

  def cookie_header(set_cookie)
    set_cookie.to_s.lines.map { |line| line.split(";").first }.join("; ")
  end
end
