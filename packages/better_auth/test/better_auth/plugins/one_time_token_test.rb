# frozen_string_literal: true

require "json"
require "rack/mock"
require_relative "../../test_helper"

class BetterAuthPluginsOneTimeTokenTest < Minitest::Test
  SECRET = "phase-eight-secret-with-enough-entropy-123"

  def test_generate_and_verify_one_time_token_consumes_it
    auth = build_auth(plugins: [BetterAuth::Plugins.one_time_token])
    cookie = sign_up_cookie(auth, email: "ott@example.com")

    generated = auth.api.generate_one_time_token(headers: {"cookie" => cookie})
    assert_match(/\A[A-Za-z0-9_-]{32}\z/, generated[:token])

    result = auth.api.verify_one_time_token(body: {token: generated[:token]})

    assert_equal "ott@example.com", result[:user]["email"]
    assert_match(/\A[0-9a-f]{32}\z/, result[:session]["token"])

    reused = assert_raises(BetterAuth::APIError) do
      auth.api.verify_one_time_token(body: {token: generated[:token]})
    end
    assert_equal 400, reused.status_code
    assert_equal "Invalid token", reused.message
  end

  def test_expired_token_and_expired_session_are_rejected
    expired = build_auth(plugins: [BetterAuth::Plugins.one_time_token(expires_in: -1)])
    expired_cookie = sign_up_cookie(expired, email: "expired-ott@example.com")
    token = expired.api.generate_one_time_token(headers: {"cookie" => expired_cookie})[:token]

    token_error = assert_raises(BetterAuth::APIError) do
      expired.api.verify_one_time_token(body: {token: token})
    end
    assert_equal 400, token_error.status_code
    assert_equal "Token expired", token_error.message

    session_expired = build_auth(plugins: [BetterAuth::Plugins.one_time_token(expires_in: 3)])
    session_cookie = sign_up_cookie(session_expired, email: "session-expired-ott@example.com")
    session = session_expired.api.get_session(headers: {"cookie" => session_cookie})
    session_token = session_expired.api.generate_one_time_token(headers: {"cookie" => session_cookie})[:token]
    session_expired.context.internal_adapter.update_session(session[:session]["token"], expiresAt: Time.now - 60)

    session_error = assert_raises(BetterAuth::APIError) do
      session_expired.api.verify_one_time_token(body: {token: session_token})
    end
    assert_equal 400, session_error.status_code
    assert_equal "Session expired", session_error.message
  end

  def test_hashed_and_custom_token_storage
    hashed = build_auth(
      plugins: [
        BetterAuth::Plugins.one_time_token(
          store_token: "hashed",
          generate_token: ->(_session, _ctx = nil) { "123456" }
        )
      ]
    )
    hashed_cookie = sign_up_cookie(hashed, email: "hashed-ott@example.com")
    token = hashed.api.generate_one_time_token(headers: {"cookie" => hashed_cookie})[:token]
    stored = hashed.context.internal_adapter.find_verification_value("one-time-token:#{BetterAuth::Crypto.sha256(token, encoding: :base64url)}")

    assert_equal "123456", token
    assert stored
    assert_nil hashed.context.internal_adapter.find_verification_value("one-time-token:123456")
    assert_equal "hashed-ott@example.com", hashed.api.verify_one_time_token(body: {token: token})[:user]["email"]

    custom = build_auth(
      plugins: [
        BetterAuth::Plugins.one_time_token(
          store_token: {type: "custom-hasher", hash: ->(value) { "#{value}:hashed" }},
          generate_token: ->(_session, _ctx = nil) { "custom-token" }
        )
      ]
    )
    custom_cookie = sign_up_cookie(custom, email: "custom-ott@example.com")
    custom_token = custom.api.generate_one_time_token(headers: {"cookie" => custom_cookie})[:token]

    assert custom.context.internal_adapter.find_verification_value("one-time-token:custom-token:hashed")
    assert_equal "custom-ott@example.com", custom.api.verify_one_time_token(body: {token: custom_token})[:user]["email"]
  end

  def test_disable_client_request_only_rejects_rack_requests
    auth = build_auth(plugins: [BetterAuth::Plugins.one_time_token(disable_client_request: true)])
    cookie = sign_up_cookie(auth, email: "server-ott@example.com")

    assert auth.api.generate_one_time_token(headers: {"cookie" => cookie})[:token]

    response = Rack::MockRequest.new(auth).get(
      "/api/auth/one-time-token/generate",
      "HTTP_COOKIE" => cookie
    )
    body = JSON.parse(response.body)

    assert_equal 400, response.status
    assert_equal "Client requests are disabled", body.fetch("message")
  end

  def test_verify_sets_session_cookie_by_default_and_can_disable_cookie
    auth = build_auth(plugins: [BetterAuth::Plugins.one_time_token])
    cookie = sign_up_cookie(auth, email: "cookie-ott@example.com")
    token = auth.api.generate_one_time_token(headers: {"cookie" => cookie})[:token]

    status, headers, _body = auth.api.verify_one_time_token(body: {token: token}, as_response: true)

    assert_equal 200, status
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token="

    disabled = build_auth(plugins: [BetterAuth::Plugins.one_time_token(disable_set_session_cookie: true)])
    disabled_cookie = sign_up_cookie(disabled, email: "no-cookie-ott@example.com")
    disabled_token = disabled.api.generate_one_time_token(headers: {"cookie" => disabled_cookie})[:token]
    _status, disabled_headers, _body = disabled.api.verify_one_time_token(body: {token: disabled_token}, as_response: true)

    refute disabled_headers.key?("set-cookie")
  end

  def test_set_ott_header_on_new_session
    auth = build_auth(plugins: [BetterAuth::Plugins.one_time_token(set_ott_header_on_new_session: true)])

    status, headers, _body = auth.api.sign_up_email(
      body: {email: "header-ott@example.com", password: "password123", name: "Header"},
      as_response: true
    )

    assert_equal 200, status
    assert_match(/\A[A-Za-z0-9_-]{32}\z/, headers.fetch("set-ott"))
    assert_includes headers.fetch("access-control-expose-headers"), "set-ott"

    sign_in_status, sign_in_headers, _sign_in_body = auth.api.sign_in_email(
      body: {email: "header-ott@example.com", password: "password123"},
      as_response: true
    )

    assert_equal 200, sign_in_status
    assert_match(/\A[A-Za-z0-9_-]{32}\z/, sign_in_headers.fetch("set-ott"))
    assert_includes sign_in_headers.fetch("access-control-expose-headers"), "set-ott"
  end

  def test_set_ott_header_is_disabled_by_default
    auth = build_auth(plugins: [BetterAuth::Plugins.one_time_token])

    _status, headers, _body = auth.api.sign_up_email(
      body: {email: "default-header-ott@example.com", password: "password123", name: "Header"},
      as_response: true
    )

    refute headers.key?("set-ott")
  end

  def test_generate_one_time_token_requires_current_session
    auth = build_auth(plugins: [BetterAuth::Plugins.one_time_token])

    error = assert_raises(BetterAuth::APIError) do
      auth.api.generate_one_time_token
    end

    assert_equal 401, error.status_code
  end

  def test_generate_one_time_token_stores_current_session_token
    auth = build_auth(plugins: [BetterAuth::Plugins.one_time_token])
    cookie = sign_up_cookie(auth, email: "stored-session@example.com")
    session = auth.api.get_session(headers: {"cookie" => cookie})

    token = auth.api.generate_one_time_token(headers: {"cookie" => cookie})[:token]
    stored = auth.context.internal_adapter.find_verification_value("one-time-token:#{token}")

    assert_equal session[:session]["token"], stored["value"]
  end

  def test_disable_client_request_only_blocks_generate_not_verify
    auth = build_auth(plugins: [BetterAuth::Plugins.one_time_token(disable_client_request: true)])
    cookie = sign_up_cookie(auth, email: "direct-verify@example.com")
    token = auth.api.generate_one_time_token(headers: {"cookie" => cookie})[:token]

    response = Rack::MockRequest.new(auth).post(
      "/api/auth/one-time-token/verify",
      "CONTENT_TYPE" => "application/json",
      :input => JSON.generate(token: token)
    )
    body = JSON.parse(response.body)

    assert_equal 200, response.status
    assert_equal "direct-verify@example.com", body.fetch("user").fetch("email")
  end

  private

  def build_auth(options = {})
    email_and_password = {enabled: true}.merge(options.fetch(:email_and_password, {}))
    BetterAuth.auth({base_url: "http://localhost:3000", secret: SECRET, database: :memory}.merge(options).merge(email_and_password: email_and_password))
  end

  def sign_up_cookie(auth, email:)
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: email, password: "password123", name: "OTT User"},
      as_response: true
    )
    cookie_header(headers.fetch("set-cookie"))
  end

  def cookie_header(set_cookie)
    set_cookie.lines.map { |line| line.split(";").first }.join("; ")
  end
end
