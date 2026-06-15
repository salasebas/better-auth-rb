# frozen_string_literal: true

require "json"
require_relative "../../test_helper"

class BetterAuthPluginsMultiSessionTest < Minitest::Test
  SECRET = "phase-seven-secret-with-enough-entropy-123"

  def test_multi_session_tracks_device_sessions_and_switches_active_session
    auth = build_auth(plugins: [BetterAuth::Plugins.multi_session(maximum_sessions: 3)])
    cookie = ""

    cookie = merge_cookie(cookie, sign_up_response(auth, email: "one@example.com"))
    cookie = merge_cookie(cookie, sign_up_response(auth, email: "two@example.com"))
    sessions = auth.api.list_device_sessions(headers: {"cookie" => cookie})

    assert_equal ["one@example.com", "two@example.com"], sessions.map { |entry| entry[:user]["email"] }.sort

    first_token = sessions.find { |entry| entry[:user]["email"] == "one@example.com" }[:session]["token"]
    switched = auth.api.set_active_session(headers: {"cookie" => cookie}, body: {sessionToken: first_token})

    assert_equal "one@example.com", switched[:user]["email"]
  end

  def test_multi_session_revoke_deletes_cookie_and_session
    auth = build_auth(plugins: [BetterAuth::Plugins.multi_session(maximum_sessions: 3)])
    cookie = merge_cookie("", sign_up_response(auth, email: "revoke-one@example.com"))
    cookie = merge_cookie(cookie, sign_up_response(auth, email: "revoke-two@example.com"))
    sessions = auth.api.list_device_sessions(headers: {"cookie" => cookie})
    token = sessions.find { |entry| entry[:user]["email"] == "revoke-one@example.com" }[:session]["token"]

    status, headers, body = auth.api.revoke_device_session(
      headers: {"cookie" => cookie},
      body: {sessionToken: token},
      as_response: true
    )

    assert_equal 200, status
    assert_equal({"status" => true}, JSON.parse(body.join))
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token_multi-#{token.downcase}="
    assert_nil auth.context.internal_adapter.find_session(token)
  end

  def test_set_active_allows_only_multi_session_cookie_but_revoke_requires_active_session
    auth = build_auth(plugins: [BetterAuth::Plugins.multi_session(maximum_sessions: 3)])
    cookie = merge_cookie("", sign_up_response(auth, email: "active-required-one@example.com"))
    cookie = merge_cookie(cookie, sign_up_response(auth, email: "active-required-two@example.com"))
    sessions = auth.api.list_device_sessions(headers: {"cookie" => cookie})
    token = sessions.first[:session]["token"]
    only_multi_session_cookies = cookie.split("; ").reject { |part| part.start_with?("better-auth.session_token=") }.join("; ")

    switched = auth.api.set_active_session(headers: {"cookie" => only_multi_session_cookies}, body: {sessionToken: token})
    assert_equal token, switched[:session]["token"]

    revoke = assert_raises(BetterAuth::APIError) do
      auth.api.revoke_device_session(headers: {"cookie" => only_multi_session_cookies}, body: {sessionToken: token})
    end
    assert_equal 401, revoke.status_code
  end

  def test_same_user_replaces_old_multi_session_cookie_even_at_maximum
    auth = build_auth(plugins: [BetterAuth::Plugins.multi_session(maximum_sessions: 1)])
    cookie = merge_cookie("", sign_up_response(auth, email: "same-user@example.com"))
    first = auth.api.list_device_sessions(headers: {"cookie" => cookie}).first
    first_token = first[:session]["token"]

    cookie = merge_cookie(cookie, sign_in_response(auth, email: "same-user@example.com", cookie: cookie))
    sessions = auth.api.list_device_sessions(headers: {"cookie" => cookie})

    assert_equal 1, sessions.length
    refute_equal first_token, sessions.first[:session]["token"]
    assert_nil auth.context.internal_adapter.find_session(first_token)
  end

  def test_revoking_active_session_sets_next_active_or_deletes_session_cookie
    auth = build_auth(plugins: [BetterAuth::Plugins.multi_session(maximum_sessions: 3)])
    cookie = merge_cookie("", sign_up_response(auth, email: "next-one@example.com"))
    cookie = merge_cookie(cookie, sign_up_response(auth, email: "next-two@example.com"))
    sessions = auth.api.list_device_sessions(headers: {"cookie" => cookie})
    active_token = auth.api.get_session(headers: {"cookie" => cookie})[:session]["token"]

    status, headers, _body = auth.api.revoke_device_session(
      headers: {"cookie" => cookie},
      body: {sessionToken: active_token},
      as_response: true
    )

    assert_equal 200, status
    replacement = merge_cookie(cookie, headers.fetch("set-cookie"))
    refute_includes replacement, "better-auth.session_token=;"
    remaining_token = sessions.map { |entry| entry[:session]["token"] }.find { |token| token != active_token }
    assert_includes replacement, "better-auth.session_token=#{remaining_token}"

    final_status, final_headers, _final_body = auth.api.revoke_device_session(
      headers: {"cookie" => replacement},
      body: {sessionToken: remaining_token},
      as_response: true
    )

    assert_equal 200, final_status
    assert_includes final_headers.fetch("set-cookie"), "better-auth.session_token=;"
  end

  def test_revoking_active_session_ignores_expired_remaining_sessions
    auth = build_auth(plugins: [BetterAuth::Plugins.multi_session(maximum_sessions: 3)])
    cookie = merge_cookie("", sign_up_response(auth, email: "expired-next-one@example.com"))
    cookie = merge_cookie(cookie, sign_up_response(auth, email: "expired-next-two@example.com"))
    sessions = auth.api.list_device_sessions(headers: {"cookie" => cookie})
    active_token = auth.api.get_session(headers: {"cookie" => cookie})[:session]["token"]
    expired_token = sessions.map { |entry| entry[:session]["token"] }.find { |token| token != active_token }
    auth.context.internal_adapter.update_session(expired_token, expiresAt: Time.now - 60)

    status, headers, _body = auth.api.revoke_device_session(
      headers: {"cookie" => cookie},
      body: {sessionToken: active_token},
      as_response: true
    )

    assert_equal 200, status
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token=;"
  end

  def test_list_device_sessions_deduplicates_same_user_and_ignores_expired
    auth = build_auth(plugins: [BetterAuth::Plugins.multi_session(maximum_sessions: 3)])
    cookie = merge_cookie("", sign_up_response(auth, email: "dedupe@example.com"))
    cookie = merge_cookie(cookie, sign_in_response(auth, email: "dedupe@example.com", cookie: cookie))
    cookie = merge_cookie(cookie, sign_up_response(auth, email: "other@example.com"))
    sessions = auth.api.list_device_sessions(headers: {"cookie" => cookie})
    expired_token = sessions.find { |entry| entry[:user]["email"] == "other@example.com" }[:session]["token"]
    auth.context.internal_adapter.update_session(expired_token, expiresAt: Time.now - 60)

    listed = auth.api.list_device_sessions(headers: {"cookie" => cookie})

    assert_equal ["dedupe@example.com"], listed.map { |entry| entry[:user]["email"] }.sort
  end

  def test_set_active_session_rejects_unknown_unsigned_and_expired_tokens
    auth = build_auth(plugins: [BetterAuth::Plugins.multi_session(maximum_sessions: 3)])
    cookie = merge_cookie("", sign_up_response(auth, email: "invalid-active@example.com"))
    sessions = auth.api.list_device_sessions(headers: {"cookie" => cookie})
    token = sessions.first[:session]["token"]

    unknown = assert_raises(BetterAuth::APIError) do
      auth.api.set_active_session(headers: {"cookie" => cookie}, body: {sessionToken: "missing-token"})
    end
    assert_equal 401, unknown.status_code

    unsigned = assert_raises(BetterAuth::APIError) do
      auth.api.set_active_session(headers: {"cookie" => "better-auth.session_token=fake"}, body: {sessionToken: token})
    end
    assert_equal 401, unsigned.status_code

    auth.context.internal_adapter.update_session(token, expiresAt: Time.now - 60)
    expired = assert_raises(BetterAuth::APIError) do
      auth.api.set_active_session(headers: {"cookie" => cookie}, body: {sessionToken: token})
    end
    assert_equal 401, expired.status_code
  end

  def test_sign_out_clears_all_multi_session_cookies
    auth = build_auth(plugins: [BetterAuth::Plugins.multi_session(maximum_sessions: 3)])
    cookie = merge_cookie("", sign_up_response(auth, email: "signout-one@example.com"))
    cookie = merge_cookie(cookie, sign_up_response(auth, email: "signout-two@example.com"))
    sessions = auth.api.list_device_sessions(headers: {"cookie" => cookie})
    multi_cookie_names = sessions.map { |entry| "better-auth.session_token_multi-#{entry[:session]["token"].downcase}" }

    status, headers, _body = auth.api.sign_out(headers: {"cookie" => cookie}, as_response: true)

    assert_equal 200, status
    multi_cookie_names.each do |name|
      assert_includes headers.fetch("set-cookie"), "#{name}=;"
    end
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token=;"
  end

  private

  def build_auth(options = {})
    email_and_password = {enabled: true}.merge(options.fetch(:email_and_password, {}))
    BetterAuth.auth({base_url: "http://localhost:3000", secret: SECRET, database: :memory}.merge(options).merge(email_and_password: email_and_password))
  end

  def sign_up_response(auth, email:)
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: email, password: "password123", name: "Multi User"},
      as_response: true
    )
    headers.fetch("set-cookie")
  end

  def sign_in_response(auth, email:, cookie:)
    _status, headers, _body = auth.api.sign_in_email(
      headers: {"cookie" => cookie},
      body: {email: email, password: "password123"},
      as_response: true
    )
    headers.fetch("set-cookie")
  end

  def merge_cookie(existing, set_cookie)
    cookies = existing.to_s.split("; ").reject(&:empty?).to_h { |part| part.split("=", 2) }
    set_cookie.lines.each do |line|
      name, value = line.split(";", 2).first.split("=", 2)
      if value.to_s.empty? || line.downcase.include?("max-age=0")
        cookies.delete(name)
      else
        cookies[name] = value
      end
    end
    cookies.map { |name, value| "#{name}=#{value}" }.join("; ")
  end

  def cookie_header(set_cookie)
    set_cookie.lines.map { |line| line.split(";").first }.join("; ")
  end
end
