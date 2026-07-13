# frozen_string_literal: true

require "json"
require_relative "../../test_helper"

class BetterAuthRoutesEmailVerificationTest < Minitest::Test
  SECRET = "phase-five-secret-with-enough-entropy-123"

  def test_send_verification_email_sends_for_unverified_user_without_leaking_missing_users
    sent = []
    auth = build_auth(email_verification: {send_verification_email: ->(data, _request = nil) { sent << data }})
    auth.api.sign_up_email(body: {email: "verify-me@example.com", password: "password123", name: "Verify"})

    assert_equal({status: true}, auth.api.send_verification_email(body: {email: "verify-me@example.com", callbackURL: "/dashboard"}))
    assert_equal({status: true}, auth.api.send_verification_email(body: {email: "missing@example.com"}))

    assert_equal 1, sent.length
    assert_equal "verify-me@example.com", sent.first[:user]["email"]
    assert_includes sent.first[:url], "/verify-email?token="
    assert_includes sent.first[:url], "callbackURL=%2Fdashboard"
  end

  def test_verification_links_only_use_canonical_or_allowlisted_serving_origins
    sent = []
    auth = build_auth(
      base_url: "https://auth.example.com",
      serving_origins: ["https://tenant.example.com"],
      trusted_origins: ["https://frontend.example.com"],
      advanced: {trusted_proxy_headers: true},
      email_verification: {send_verification_email: ->(data, _request = nil) { sent << data }}
    )
    auth.api.sign_up_email(body: {email: "host-boundary@example.com", password: "password123", name: "Verify"})

    auth.api.send_verification_email(
      headers: {"host" => "attacker.example", "x-forwarded-host" => "proxy-attacker.example", "x-forwarded-proto" => "https"},
      body: {email: "host-boundary@example.com"}
    )
    auth.api.send_verification_email(
      headers: {"host" => "frontend.example.com"},
      body: {email: "host-boundary@example.com"}
    )
    auth.api.send_verification_email(
      headers: {"host" => "tenant.example.com"},
      body: {email: "host-boundary@example.com"}
    )

    assert sent[0].fetch(:url).start_with?("https://auth.example.com/api/auth/verify-email?")
    assert sent[1].fetch(:url).start_with?("https://auth.example.com/api/auth/verify-email?")
    assert sent[2].fetch(:url).start_with?("https://tenant.example.com/api/auth/verify-email?")
  end

  def test_send_verification_email_rejects_mismatched_authenticated_user
    sent = []
    auth = build_auth(email_verification: {send_verification_email: ->(data, _request = nil) { sent << data }})
    cookie = sign_up_cookie(auth, email: "session-email@example.com")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.send_verification_email(headers: {"cookie" => cookie}, body: {email: "other@example.com"})
    end

    assert_equal 400, error.status_code
    assert_equal BetterAuth::BASE_ERROR_CODES["EMAIL_MISMATCH"], error.message
    assert_empty sent
  end

  def test_verify_email_marks_user_verified_and_can_set_session_cookie
    verified = []
    auth = build_auth(
      email_verification: {
        auto_sign_in_after_verification: true,
        before_email_verification: ->(user, _request = nil) { verified << "before:#{user["email"]}" },
        on_email_verification: ->(user, _request = nil) { verified << "on:#{user["email"]}" },
        after_email_verification: ->(user, _request = nil) { verified << "after:#{user["email"]}" }
      }
    )
    auth.api.sign_up_email(body: {email: "verified@example.com", password: "password123", name: "Verified"})
    token = BetterAuth::Crypto.sign_jwt({"email" => "verified@example.com"}, SECRET, expires_in: 3600)

    status, headers, body = auth.api.verify_email(query: {token: token}, as_response: true)

    assert_equal 200, status
    assert_equal({"status" => true, "user" => nil}, JSON.parse(body.join))
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token="
    assert_equal ["before:verified@example.com", "on:verified@example.com", "after:verified@example.com"], verified
    user = auth.context.internal_adapter.find_user_by_email("verified@example.com")[:user]
    assert_equal true, user["emailVerified"]
    assert_nil auth.context.internal_adapter.find_verification_value("change-email:#{BetterAuth::Crypto.sha256(token, encoding: :base64url)}")
  end

  def test_verify_email_auto_sign_in_exposes_bearer_set_auth_token_header
    auth = build_auth(
      plugins: [BetterAuth::Plugins.bearer],
      email_verification: {auto_sign_in_after_verification: true}
    )
    auth.api.sign_up_email(body: {email: "bearer-verified@example.com", password: "password123", name: "Verified"})
    token = BetterAuth::Crypto.sign_jwt({"email" => "bearer-verified@example.com"}, SECRET, expires_in: 3600)

    status, headers, _body = auth.api.verify_email(query: {token: token}, as_response: true)
    session_token = headers.fetch("set-auth-token")
    session = auth.api.get_session(headers: {"authorization" => "Bearer #{session_token}"})

    assert_equal 200, status
    assert_operator session_token.length, :>, 10
    assert_equal "bearer-verified@example.com", session[:user]["email"]
    assert_equal true, session[:user]["emailVerified"]
  end

  def test_verify_email_auto_sign_in_does_not_reuse_different_users_session
    auth = build_auth(email_verification: {auto_sign_in_after_verification: true})
    first_cookie = sign_up_cookie(auth, email: "already-signed-in@example.com")
    first_session = auth.api.get_session(headers: {"cookie" => first_cookie})
    auth.api.sign_up_email(body: {email: "verified-other-user@example.com", password: "password123", name: "Other"})
    token = BetterAuth::Crypto.sign_jwt({"email" => "verified-other-user@example.com"}, SECRET, expires_in: 3600)

    _status, headers, _body = auth.api.verify_email(
      headers: {"cookie" => first_cookie},
      query: {token: token},
      as_response: true
    )
    refreshed_cookie = cookie_header(headers.fetch("set-cookie"))
    session = auth.api.get_session(headers: {"cookie" => refreshed_cookie})

    assert_equal "verified-other-user@example.com", session[:user]["email"]
    refute_equal first_session[:session]["token"], session[:session]["token"]
  end

  def test_verify_email_redirects_to_callback_url_with_existing_query
    auth = build_auth
    auth.api.sign_up_email(body: {email: "redirect-verified@example.com", password: "password123", name: "Verified"})
    token = BetterAuth::Crypto.sign_jwt({"email" => "redirect-verified@example.com"}, SECRET, expires_in: 3600)

    status, headers, _body = auth.api.verify_email(
      query: {token: token, callbackURL: "/dashboard?from=email"},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/dashboard?from=email", headers.fetch("location")
  end

  def test_verify_email_rejects_expired_token
    auth = build_auth
    auth.api.sign_up_email(body: {email: "expired-token@example.com", password: "password123", name: "Expired"})
    token = BetterAuth::Crypto.sign_jwt({"email" => "expired-token@example.com"}, SECRET, expires_in: -1)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_email(query: {token: token})
    end

    assert_equal 401, error.status_code
    assert_equal "TOKEN_EXPIRED", error.code
    assert_equal BetterAuth::BASE_ERROR_CODES["TOKEN_EXPIRED"], error.message
  end

  def test_verify_email_rejects_untrusted_callback_url
    auth = build_auth
    auth.api.sign_up_email(body: {email: "unsafe-callback@example.com", password: "password123", name: "Unsafe"})
    token = BetterAuth::Crypto.sign_jwt({"email" => "unsafe-callback@example.com"}, SECRET, expires_in: 3600)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_email(query: {token: token, callbackURL: "https://evil.example/callback"})
    end

    assert_equal 400, error.status_code
    assert_equal BetterAuth::BASE_ERROR_CODES["INVALID_CALLBACK_URL"], error.message
  end

  def test_change_email_verification_updates_email_as_verified
    sent = []
    auth = build_auth(
      user: {change_email: {enabled: true}},
      email_verification: {send_verification_email: ->(data, _request = nil) { sent << data }}
    )
    cookie = sign_up_cookie(auth, email: "old-verified@example.com")
    auth.context.internal_adapter.update_user_by_email("old-verified@example.com", emailVerified: true)

    assert_equal({status: true}, auth.api.change_email(headers: {"cookie" => cookie}, body: {newEmail: "new-verified@example.com"}))
    first_token = sent.first.fetch(:token)

    status, headers, _body = auth.api.verify_email(query: {token: first_token}, as_response: true)
    redeemed_cookie = cookie_header(headers.fetch("set-cookie"))
    redeemed_session = auth.api.get_session(headers: {"cookie" => redeemed_cookie})

    assert_equal 200, status
    assert_equal "new-verified@example.com", redeemed_session[:user]["email"]
    assert_equal true, redeemed_session[:user]["emailVerified"]
    old_user = auth.context.internal_adapter.find_user_by_email("old-verified@example.com")
    new_user = auth.context.internal_adapter.find_user_by_email("new-verified@example.com")[:user]
    assert_nil old_user
    assert_equal true, new_user["emailVerified"]
    assert_equal 1, sent.length
    assert_equal "new-verified@example.com", sent.first.fetch(:user).fetch("email")
  end

  def test_send_verification_email_rejects_already_verified_authenticated_user
    sent = []
    auth = build_auth(email_verification: {send_verification_email: ->(data, _request = nil) { sent << data }})
    cookie = sign_up_cookie(auth, email: "already-verified@example.com")
    auth.context.internal_adapter.update_user_by_email("already-verified@example.com", emailVerified: true)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.send_verification_email(headers: {"cookie" => cookie}, body: {email: "already-verified@example.com"})
    end

    assert_equal 400, error.status_code
    assert_equal BetterAuth::BASE_ERROR_CODES["EMAIL_ALREADY_VERIFIED"], error.message
    assert_empty sent
  end

  def test_verify_email_invalid_token_redirects_with_error_when_callback_is_present
    auth = build_auth

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_email(query: {token: "invalid-token", callbackURL: "/dashboard"})
    end

    assert_equal 302, error.status_code
    assert_includes error.headers.fetch("location"), "/dashboard"
    assert_includes error.headers.fetch("location"), "error=INVALID_TOKEN"
  end

  def test_verify_email_auto_sign_in_stores_session_in_secondary_storage
    storage = StringStorage.new
    auth = build_auth(
      secondary_storage: storage,
      email_verification: {auto_sign_in_after_verification: true}
    )
    auth.api.sign_up_email(body: {email: "secondary-verified@example.com", password: "password123", name: "Verified"})
    token = BetterAuth::Crypto.sign_jwt({"email" => "secondary-verified@example.com"}, SECRET, expires_in: 3600)

    status, headers, _body = auth.api.verify_email(query: {token: token}, as_response: true)
    cookie = cookie_header(headers.fetch("set-cookie"))
    session = auth.api.get_session(headers: {"cookie" => cookie})

    assert_equal 200, status
    assert_equal "secondary-verified@example.com", session[:user]["email"]
    assert_equal true, session[:user]["emailVerified"]
    assert storage.get(session[:session]["token"])
    assert storage.get("active-sessions-#{session[:user]["id"]}")
  end

  def test_verify_email_refreshes_email_verified_on_all_secondary_storage_sessions
    storage = StringStorage.new
    auth = build_auth(secondary_storage: storage)
    first_cookie = sign_up_cookie(auth, email: "all-sessions@example.com")
    _status, second_headers, _body = auth.api.sign_in_email(
      body: {email: "all-sessions@example.com", password: "password123"},
      as_response: true
    )
    second_cookie = cookie_header(second_headers.fetch("set-cookie"))
    token = BetterAuth::Crypto.sign_jwt({"email" => "all-sessions@example.com"}, SECRET, expires_in: 3600)

    auth.api.verify_email(query: {token: token})

    first_session = auth.api.get_session(headers: {"cookie" => first_cookie})
    second_session = auth.api.get_session(headers: {"cookie" => second_cookie})
    first_stored = JSON.parse(storage.get(first_session[:session]["token"]))
    second_stored = JSON.parse(storage.get(second_session[:session]["token"]))

    assert_equal true, first_session[:user]["emailVerified"]
    assert_equal true, second_session[:user]["emailVerified"]
    assert_equal true, first_stored.fetch("user").fetch("emailVerified")
    assert_equal true, second_stored.fetch("user").fetch("emailVerified")
  end

  def test_change_email_updates_secondary_storage_session_after_verification
    storage = StringStorage.new
    sent = []
    auth = build_auth(
      secondary_storage: storage,
      user: {change_email: {enabled: true}},
      email_verification: {send_verification_email: ->(data, _request = nil) { sent << data }}
    )
    cookie = sign_up_cookie(auth, email: "old-secondary-email@example.com")

    result = auth.api.change_email(headers: {"cookie" => cookie}, body: {newEmail: "new-secondary-email@example.com"})
    assert_equal({status: true}, result)

    status, headers, _body = auth.api.verify_email(
      headers: {"cookie" => cookie},
      query: {token: sent.first.fetch(:token)},
      as_response: true
    )
    refreshed_cookie = cookie_header(headers.fetch("set-cookie"))
    session = auth.api.get_session(headers: {"cookie" => refreshed_cookie})
    stored_session = JSON.parse(storage.get(session[:session]["token"]))

    assert_equal 200, status
    assert_equal "new-secondary-email@example.com", session[:user]["email"]
    assert_equal true, session[:user]["emailVerified"]
    assert_equal 1, sent.length
    assert_equal "new-secondary-email@example.com", stored_session.fetch("user").fetch("email")
    assert_equal true, stored_session.fetch("user").fetch("emailVerified")
  end

  def test_change_email_confirmation_sends_old_email_confirmation_before_new_email_verification
    confirmations = []
    verifications = []
    after_calls = []
    auth = build_auth(
      user: {
        change_email: {
          enabled: true,
          send_change_email_confirmation: ->(data, _request = nil) { confirmations << data }
        }
      },
      email_verification: {
        send_verification_email: ->(data, _request = nil) { verifications << data },
        after_email_verification: ->(user, _request = nil) { after_calls << user["email"] }
      }
    )
    cookie = sign_up_cookie(auth, email: "confirmed-old@example.com")
    auth.context.internal_adapter.update_user_by_email("confirmed-old@example.com", emailVerified: true)

    result = auth.api.change_email(
      headers: {"cookie" => cookie},
      body: {newEmail: "confirmed-new@example.com", callbackURL: "/settings"}
    )

    assert_equal({status: true}, result)
    assert_equal 1, confirmations.length
    assert_empty verifications
    assert_equal "confirmed-old@example.com", confirmations.first.fetch(:user).fetch("email")
    assert_equal "confirmed-new@example.com", confirmations.first.fetch(:new_email)
    assert_includes confirmations.first.fetch(:url), "/verify-email?token="
    assert_includes confirmations.first.fetch(:url), "callbackURL=%2Fsettings"

    auth.api.verify_email(headers: {"cookie" => cookie}, query: {token: confirmations.first.fetch(:token)})
    assert_equal 1, verifications.length
    assert_equal "confirmed-new@example.com", verifications.first.fetch(:user).fetch("email")
    assert_includes verifications.first.fetch(:url), "/verify-email?token="
    assert auth.context.internal_adapter.find_user_by_email("confirmed-old@example.com")
    assert_nil auth.context.internal_adapter.find_user_by_email("confirmed-new@example.com")

    status, headers, body = auth.api.verify_email(
      headers: {"cookie" => cookie},
      query: {token: verifications.first.fetch(:token)},
      as_response: true
    )
    refreshed_cookie = cookie_header(headers.fetch("set-cookie"))
    session = auth.api.get_session(headers: {"cookie" => refreshed_cookie})
    payload = JSON.parse(body.join)

    assert_equal 200, status
    assert_equal true, payload.fetch("status")
    assert_equal "confirmed-new@example.com", payload.fetch("user").fetch("email")
    assert_equal true, payload.fetch("user").fetch("emailVerified")
    assert_equal "confirmed-new@example.com", session[:user]["email"]
    assert_equal true, session[:user]["emailVerified"]
    assert_nil auth.context.internal_adapter.find_user_by_email("confirmed-old@example.com")
    assert_equal ["confirmed-new@example.com"], after_calls
  end

  def test_change_email_verification_rejects_a_different_users_session_without_mutation
    sent = []
    auth = build_auth(
      user: {change_email: {enabled: true}},
      email_verification: {send_verification_email: ->(data, _request = nil) { sent << data }}
    )
    owner_cookie = sign_up_cookie(auth, email: "change-owner@example.com")
    other_cookie = sign_up_cookie(auth, email: "signed-in-other@example.com")
    auth.context.internal_adapter.update_user_by_email("change-owner@example.com", emailVerified: true)
    auth.api.change_email(headers: {"cookie" => owner_cookie}, body: {newEmail: "change-target@example.com"})

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_email(headers: {"cookie" => other_cookie}, query: {token: sent.fetch(0).fetch(:token)})
    end

    assert_equal 401, error.status_code
    assert_equal "invalid_user", error.message
    assert auth.context.internal_adapter.find_user_by_email("change-owner@example.com")
    assert_nil auth.context.internal_adapter.find_user_by_email("change-target@example.com")

    status, headers, _body = auth.api.verify_email(query: {token: sent.fetch(0).fetch(:token)}, as_response: true)
    session = auth.api.get_session(headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))})

    assert_equal 200, status
    assert_equal "change-target@example.com", session[:user]["email"]
  end

  def test_change_email_verification_creates_session_before_mutating_email
    sent = []
    auth = build_auth(
      user: {change_email: {enabled: true}},
      email_verification: {send_verification_email: ->(data, _request = nil) { sent << data }}
    )
    cookie = sign_up_cookie(auth, email: "session-failure-old@example.com")
    auth.context.internal_adapter.update_user_by_email("session-failure-old@example.com", emailVerified: true)
    auth.api.change_email(headers: {"cookie" => cookie}, body: {newEmail: "session-failure-new@example.com"})
    auth.context.internal_adapter.define_singleton_method(:create_session) { |*_args| nil }

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_email(query: {token: sent.fetch(0).fetch(:token)})
    end

    assert_equal 500, error.status_code
    assert_equal BetterAuth::BASE_ERROR_CODES["FAILED_TO_CREATE_SESSION"], error.message
    assert auth.context.internal_adapter.find_user_by_email("session-failure-old@example.com")
    assert_nil auth.context.internal_adapter.find_user_by_email("session-failure-new@example.com")
  end

  def test_legacy_update_to_token_remains_storeless_and_creates_session_before_mutation
    auth = build_auth
    auth.api.sign_up_email(body: {email: "legacy-old@example.com", password: "password123", name: "Legacy"})
    token = BetterAuth::Crypto.sign_jwt(
      {"email" => "legacy-old@example.com", "updateTo" => "legacy-new@example.com"},
      SECRET,
      expires_in: 3600
    )

    status, headers, _body = auth.api.verify_email(query: {token: token}, as_response: true)
    session = auth.api.get_session(headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))})

    assert_equal 200, status
    assert_equal "legacy-new@example.com", session[:user]["email"]
    assert_equal false, session[:user]["emailVerified"]
    assert_nil auth.context.internal_adapter.find_verification_value("change-email:#{BetterAuth::Crypto.sha256(token, encoding: :base64url)}")
  end

  def test_legacy_update_to_session_creation_failure_leaves_email_unchanged
    auth = build_auth
    auth.api.sign_up_email(body: {email: "legacy-failure-old@example.com", password: "password123", name: "Legacy"})
    token = BetterAuth::Crypto.sign_jwt(
      {"email" => "legacy-failure-old@example.com", "updateTo" => "legacy-failure-new@example.com"},
      SECRET,
      expires_in: 3600
    )
    auth.context.internal_adapter.define_singleton_method(:create_session) { |*_args| nil }

    error = assert_raises(BetterAuth::APIError) { auth.api.verify_email(query: {token: token}) }

    assert_equal 500, error.status_code
    assert auth.context.internal_adapter.find_user_by_email("legacy-failure-old@example.com")
    assert_nil auth.context.internal_adapter.find_user_by_email("legacy-failure-new@example.com")
  end

  def test_change_email_verification_rejects_tampered_update_to_without_mutation
    sent = []
    auth = build_auth(
      user: {change_email: {enabled: true}},
      email_verification: {send_verification_email: ->(data, _request = nil) { sent << data }}
    )
    cookie = sign_up_cookie(auth, email: "tamper-old@example.com")
    auth.api.change_email(headers: {"cookie" => cookie}, body: {newEmail: "tamper-new@example.com"})
    token = sent.fetch(0).fetch(:token)
    header, _payload, signature = token.split(".")
    decoded, = JWT.decode(token, nil, false)
    decoded["updateTo"] = "attacker@example.com"
    tampered_payload = Base64.urlsafe_encode64(JSON.generate(decoded), padding: false)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_email(query: {token: [header, tampered_payload, signature].join(".")})
    end

    assert_equal BetterAuth::BASE_ERROR_CODES["INVALID_TOKEN"], error.message
    assert auth.context.internal_adapter.find_user_by_email("tamper-old@example.com")
    assert_nil auth.context.internal_adapter.find_user_by_email("tamper-new@example.com")
    assert_nil auth.context.internal_adapter.find_user_by_email("attacker@example.com")
  end

  def test_change_email_confirmation_is_single_use_and_replay_has_no_email_side_effect
    confirmations = []
    verifications = []
    auth = build_auth(
      user: {
        change_email: {
          enabled: true,
          send_change_email_confirmation: ->(data, _request = nil) { confirmations << data }
        }
      },
      email_verification: {send_verification_email: ->(data, _request = nil) { verifications << data }}
    )
    cookie = sign_up_cookie(auth, email: "single-confirm-old@example.com")
    auth.context.internal_adapter.update_user_by_email("single-confirm-old@example.com", emailVerified: true)
    auth.api.change_email(headers: {"cookie" => cookie}, body: {newEmail: "single-confirm-new@example.com"})
    token = confirmations.fetch(0).fetch(:token)

    auth.api.verify_email(query: {token: token})
    error = assert_raises(BetterAuth::APIError) { auth.api.verify_email(query: {token: token}) }

    assert_equal BetterAuth::BASE_ERROR_CODES["TOKEN_ALREADY_USED"], error.message
    assert_equal "TOKEN_ALREADY_USED", error.code
    assert_equal 1, verifications.length
    assert auth.context.internal_adapter.find_user_by_email("single-confirm-old@example.com")
  end

  def test_change_email_verification_is_single_use_and_replay_has_no_hooks_or_sessions
    sent = []
    hooks = []
    auth = build_auth(
      user: {change_email: {enabled: true}},
      email_verification: {
        send_verification_email: ->(data, _request = nil) { sent << data },
        after_email_verification: ->(user, _request = nil) { hooks << user["email"] }
      }
    )
    cookie = sign_up_cookie(auth, email: "single-verify-old@example.com")
    auth.api.change_email(headers: {"cookie" => cookie}, body: {newEmail: "single-verify-new@example.com"})
    token = sent.fetch(0).fetch(:token)

    auth.api.verify_email(query: {token: token})
    sessions_after_first_use = auth.context.adapter.find_many(model: "session").length
    error = assert_raises(BetterAuth::APIError) { auth.api.verify_email(query: {token: token}) }

    assert_equal BetterAuth::BASE_ERROR_CODES["TOKEN_ALREADY_USED"], error.message
    assert_equal ["single-verify-new@example.com"], hooks
    assert_equal sessions_after_first_use, auth.context.adapter.find_many(model: "session").length
  end

  def test_change_email_token_is_registered_under_a_hash_not_the_raw_jwt
    sent = []
    auth = build_auth(
      user: {change_email: {enabled: true}},
      email_verification: {send_verification_email: ->(data, _request = nil) { sent << data }}
    )
    cookie = sign_up_cookie(auth, email: "stored-token-old@example.com")
    auth.api.change_email(headers: {"cookie" => cookie}, body: {newEmail: "stored-token-new@example.com"})
    token = sent.fetch(0).fetch(:token)
    identifier = "change-email:#{BetterAuth::Crypto.sha256(token, encoding: :base64url)}"
    stored = auth.context.internal_adapter.find_verification_value(identifier)

    assert stored
    assert_equal identifier, stored["identifier"]
    refute_includes stored["identifier"], token
    refute_equal token, stored["value"]
  end

  def test_change_email_consumption_deletes_duplicate_identifier_records
    sent = []
    auth = build_auth(
      user: {change_email: {enabled: true}},
      email_verification: {send_verification_email: ->(data, _request = nil) { sent << data }}
    )
    cookie = sign_up_cookie(auth, email: "duplicate-token-old@example.com")
    auth.api.change_email(headers: {"cookie" => cookie}, body: {newEmail: "duplicate-token-new@example.com"})
    token = sent.fetch(0).fetch(:token)
    identifier = "change-email:#{BetterAuth::Crypto.sha256(token, encoding: :base64url)}"
    auth.context.internal_adapter.create_verification_value(
      identifier: identifier,
      value: "duplicate",
      expiresAt: Time.now + 3600
    )

    assert_equal 2, auth.context.adapter.find_many(model: "verification", where: [{field: "identifier", value: identifier}]).length

    auth.api.verify_email(query: {token: token})
    error = assert_raises(BetterAuth::APIError) { auth.api.verify_email(query: {token: token}) }

    assert_equal BetterAuth::BASE_ERROR_CODES["TOKEN_ALREADY_USED"], error.message
    assert_nil auth.context.internal_adapter.find_verification_value(identifier)
    assert_empty auth.context.adapter.find_many(model: "verification", where: [{field: "identifier", value: identifier}])
  end

  private

  def build_auth(options = {})
    email_and_password = {enabled: true}.merge(options.fetch(:email_and_password, {}))
    BetterAuth.auth({base_url: "http://localhost:3000", secret: SECRET, database: :memory}.merge(options).merge(email_and_password: email_and_password))
  end

  def sign_up_cookie(auth, email:)
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: email, password: "password123", name: "Email User"},
      as_response: true
    )
    headers.fetch("set-cookie").lines.map { |line| line.split(";").first }.join("; ")
  end

  def cookie_header(set_cookie)
    set_cookie.lines.map { |line| line.split(";").first }.join("; ")
  end

  class StringStorage
    def initialize
      @store = {}
      @mutex = Mutex.new
    end

    def set(key, value, _ttl = nil)
      @store[key] = value
    end

    def get(key)
      @store[key]
    end

    def delete(key)
      @store.delete(key)
    end

    def get_and_delete(key)
      @mutex.synchronize { @store.delete(key) }
    end
  end
end
