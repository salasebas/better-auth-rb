# frozen_string_literal: true

require_relative "../../test_helper"

class BetterAuthPluginsBearerTest < Minitest::Test
  SECRET = "phase-seven-secret-with-enough-entropy-123"

  def test_bearer_exposes_auth_token_and_accepts_authorization_header
    auth = build_auth(plugins: [BetterAuth::Plugins.bearer])

    _status, headers, _body = auth.api.sign_up_email(
      body: {email: "bearer@example.com", password: "password123", name: "Bearer"},
      as_response: true
    )
    token = headers.fetch("set-auth-token")

    session = auth.api.get_session(headers: {"authorization" => "Bearer #{token}"})

    assert_equal "bearer@example.com", session[:user]["email"]
  end

  def test_bearer_authorizes_list_sessions
    auth = build_auth(plugins: [BetterAuth::Plugins.bearer])
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: "bearer-list@example.com", password: "password123", name: "Bearer"},
      as_response: true
    )
    token = headers.fetch("set-auth-token")

    sessions = auth.api.list_sessions(headers: {"authorization" => "Bearer #{token}"})

    assert_equal 1, sessions.length
    assert_equal auth.api.get_session(headers: {"authorization" => "Bearer #{token}"})[:session]["userId"], sessions.first["userId"]
  end

  def test_bearer_works_with_direct_api_headers
    auth = build_auth(plugins: [BetterAuth::Plugins.bearer])
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: "bearer-direct@example.com", password: "password123", name: "Bearer"},
      as_response: true
    )
    token = headers.fetch("set-auth-token")

    session = auth.api.get_session(headers: {"Authorization" => "Bearer #{token}"})

    assert_equal "bearer-direct@example.com", session[:user]["email"]
  end

  def test_bearer_accepts_unsigned_token_when_signature_is_not_required
    auth = build_auth(plugins: [BetterAuth::Plugins.bearer])
    result = auth.api.sign_up_email(body: {email: "raw-bearer@example.com", password: "password123", name: "Bearer"})

    session = auth.api.get_session(headers: {"authorization" => "Bearer #{result[:token]}"})

    assert_equal "raw-bearer@example.com", session[:user]["email"]
  end

  def test_bearer_rejects_unsigned_token_when_signature_is_required
    auth = build_auth(plugins: [BetterAuth::Plugins.bearer(require_signature: true)])
    result = auth.api.sign_up_email(body: {email: "signed-only@example.com", password: "password123", name: "Bearer"})

    session = auth.api.get_session(headers: {"authorization" => "Bearer #{result[:token]}"})

    assert_nil session
  end

  def test_bearer_ignores_non_bearer_authorization_headers
    auth = build_auth(plugins: [BetterAuth::Plugins.bearer])
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: "bearer-basic@example.com", password: "password123", name: "Bearer"},
      as_response: true
    )
    token = headers.fetch("set-auth-token")

    ["Basic #{token}", token].each do |authorization|
      session = auth.api.get_session(headers: {"authorization" => authorization})

      assert_nil session
    end
  end

  def test_bearer_ignores_empty_bearer_token
    auth = build_auth(plugins: [BetterAuth::Plugins.bearer])

    session = auth.api.get_session(headers: {"authorization" => "Bearer   "})

    assert_nil session
  end

  def test_bearer_scheme_is_case_insensitive_and_allows_extra_whitespace
    auth = build_auth(plugins: [BetterAuth::Plugins.bearer])
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: "bearer-scheme@example.com", password: "password123", name: "Bearer"},
      as_response: true
    )
    token = headers.fetch("set-auth-token")

    ["bearer", "BEARER", "BeArEr", "Bearer   "].each do |scheme|
      session = auth.api.get_session(headers: {"authorization" => "#{scheme} #{token}"})

      assert_equal "bearer-scheme@example.com", session[:user]["email"]
    end
  end

  def test_bearer_accepts_url_encoded_and_decoded_signed_tokens
    auth = build_auth(plugins: [BetterAuth::Plugins.bearer])
    signed_token = signed_session_token(auth, token: "session/token with spaces")
    encoded_token = signed_token.gsub("/", "%2F").gsub(" ", "%20")

    [encoded_token, signed_token].each do |token|
      session = auth.api.get_session(headers: {"authorization" => "Bearer #{token}"})

      assert_equal "bearer-encoded@example.com", session[:user]["email"]
    end
  end

  def test_bearer_falls_back_to_valid_cookie_when_authorization_header_is_invalid
    auth = build_auth(plugins: [BetterAuth::Plugins.bearer])
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: "bearer-cookie@example.com", password: "password123", name: "Bearer"},
      as_response: true
    )
    token = headers.fetch("set-auth-token")

    session = auth.api.get_session(
      headers: {
        "authorization" => "Bearer invalid.token",
        "cookie" => "better-auth.session_token=#{token}"
      }
    )

    assert_equal "bearer-cookie@example.com", session[:user]["email"]
  end

  def test_bearer_replaces_an_existing_session_cookie_and_encodes_the_manual_value
    auth = build_auth(plugins: [BetterAuth::Plugins.bearer])
    signed_token = signed_session_token(auth, token: "session/token with spaces")
    cookie_name = auth.context.auth_cookies[:session_token].name
    ctx = BetterAuth::Endpoint::Context.new(
      path: "/get-session",
      method: "GET",
      query: {},
      body: {},
      params: {},
      headers: {"authorization" => "Bearer #{signed_token}", "cookie" => "other=keep; #{cookie_name}=stale"},
      context: auth.context
    )

    result = BetterAuth::Plugins.apply_bearer_token(ctx, {})
    cookie = result.fetch(:context).fetch(:headers).fetch("cookie")

    assert_equal 1, cookie.scan(/#{Regexp.escape(cookie_name)}=/).length
    assert_includes cookie, "other=keep"
    assert_includes cookie, "session%2Ftoken%20with%20spaces"
  end

  def test_bearer_does_not_expose_expired_session_cookie_as_auth_token
    auth = build_auth(plugins: [BetterAuth::Plugins.bearer])
    cookie_name = auth.context.auth_cookies[:session_token].name
    ctx = BetterAuth::Endpoint::Context.new(
      path: "/sign-out",
      method: "POST",
      query: {},
      body: {},
      params: {},
      headers: {},
      context: auth.context
    )
    ctx.response_headers["set-cookie"] = "#{cookie_name}=stale.token; Path=/; Max-Age=0; HttpOnly; SameSite=lax"

    BetterAuth::Plugins.expose_auth_token(ctx)

    refute ctx.response_headers.key?("set-auth-token")
  end

  private

  def build_auth(options = {})
    email_and_password = {enabled: true}.merge(options.fetch(:email_and_password, {}))
    BetterAuth.auth({base_url: "http://localhost:3000", secret: SECRET, database: :memory}.merge(options).merge(email_and_password: email_and_password))
  end

  def signed_session_token(auth, token:)
    result = auth.api.sign_up_email(body: {email: "bearer-encoded@example.com", password: "password123", name: "Bearer"})
    auth.context.internal_adapter.create_session(result[:user].fetch("id"), false, {token: token}, true)
    signature = BetterAuth::Crypto.hmac_signature(token, SECRET, encoding: :base64url)
    "#{token}.#{signature}"
  end
end
