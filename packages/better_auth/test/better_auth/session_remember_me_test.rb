# frozen_string_literal: true

require "json"
require_relative "../test_helper"

class BetterAuthSessionRememberMeTest < Minitest::Test
  SECRET = "remember-me-secret-with-enough-entropy-123"
  STRATEGIES = %w[compact jwt jwe].freeze
  SESSION_EXPIRES_IN = 600
  CACHE_MAX_AGE = 300
  CREATED_AT = Time.utc(2026, 7, 26, 12, 0, 0)

  def test_session_creation_preserves_omitted_true_and_false_remember_me_semantics
    STRATEGIES.each do |strategy|
      auth = build_auth(strategy: strategy)

      [[:omitted, nil], [:remembered, true], [:session_only, false]].each do |label, remember_me|
        email = "#{strategy}-#{label}@example.com"
        create_user(auth, email)

        Time.stub(:now, CREATED_AT) do
          status, headers, body = sign_in(auth, email, remember_me: remember_me)

          assert_equal 200, status
          response = JSON.parse(body.join)
          cookies = parsed_set_cookies(headers.fetch("set-cookie"))
          token_cookie = cookies.fetch(auth.context.auth_cookies[:session_token].name)
          data_cookie = cookies.fetch(auth.context.auth_cookies[:session_data].name)
          marker_name = auth.context.auth_cookies[:dont_remember].name
          stored = auth.context.internal_adapter.find_session(response.fetch("token")).fetch(:session)
          expected_lifetime = (remember_me == false) ? 86_400 : SESSION_EXPIRES_IN

          assert_equal CREATED_AT + expected_lifetime, stored.fetch("expiresAt")
          assert_marker_not_embedded(stored)

          if remember_me == false
            assert_session_cookie(token_cookie)
            assert_session_cookie(data_cookie)
            assert_equal "true", signed_cookie_value(auth, headers.fetch("set-cookie"), marker_name)
          else
            assert_persistent_cookie(token_cookie, SESSION_EXPIRES_IN)
            assert_persistent_cookie(data_cookie, CACHE_MAX_AGE)
            refute cookies.key?(marker_name)
          end

          cache = decoded_cache(auth, strategy, headers.fetch("set-cookie"))
          assert_marker_not_embedded(cache)
          assert_marker_not_embedded(cache.fetch("session"))
        end
      end
    end
  end

  def test_omitted_setter_argument_infers_signed_marker_and_explicit_values_override_it
    auth = build_auth(strategy: "compact")
    session = sample_session
    marker_header = signed_marker_header(auth)

    inferred = endpoint_context(auth, cookie: marker_header)
    BetterAuth::Cookies.set_session_cookie(inferred, session)
    assert_session_cookies(inferred.response_headers.fetch("set-cookie"), auth, persistent_for: nil)

    inferred_with_override = endpoint_context(auth, cookie: marker_header)
    BetterAuth::Cookies.set_session_cookie(inferred_with_override, session, nil, max_age: 42)
    assert_mixed_session_cookies(inferred_with_override.response_headers.fetch("set-cookie"), auth, token_persistent_for: 42, data_persistent_for: nil)

    explicit_remember = endpoint_context(auth, cookie: marker_header)
    BetterAuth::Cookies.set_session_cookie(explicit_remember, session, false, max_age: 42)
    assert_session_cookies(explicit_remember.response_headers.fetch("set-cookie"), auth, persistent_for: 42)

    explicit_dont_remember = endpoint_context(auth)
    BetterAuth::Cookies.set_session_cookie(explicit_dont_remember, session, true)
    assert_session_cookies(explicit_dont_remember.response_headers.fetch("set-cookie"), auth, persistent_for: nil)

    explicit_dont_remember_with_override = endpoint_context(auth)
    BetterAuth::Cookies.set_session_cookie(explicit_dont_remember_with_override, session, true, max_age: 42)
    assert_mixed_session_cookies(explicit_dont_remember_with_override.response_headers.fetch("set-cookie"), auth, token_persistent_for: 42, data_persistent_for: nil)
  end

  def test_stateless_cache_refresh_keeps_dont_remember_session_cookies_session_only
    STRATEGIES.each do |strategy|
      auth = build_auth(
        strategy: strategy,
        database: nil,
        refresh_cache: {update_age: 120}
      )
      email = "stateless-#{strategy}@example.com"
      create_user(auth, email)

      initial_cookie = Time.stub(:now, CREATED_AT) do
        _status, headers, _body = sign_in(auth, email, remember_me: false)
        cookie_header(headers.fetch("set-cookie"))
      end

      Time.stub(:now, CREATED_AT + 240) do
        status, headers, _body = auth.api.get_session(headers: {"cookie" => initial_cookie}, as_response: true)

        assert_equal 200, status
        assert_session_cookies(headers.fetch("set-cookie"), auth, persistent_for: nil)
      end
    end
  end

  def test_stateful_backing_fallback_does_not_refresh_dont_remember_session
    STRATEGIES.each do |strategy|
      auth = build_auth(strategy: strategy, update_age: 60)
      email = "stateful-#{strategy}@example.com"
      create_user(auth, email)

      initial_cookie = Time.stub(:now, CREATED_AT) do
        _status, headers, _body = sign_in(auth, email, remember_me: false)
        without_cookie(cookie_header(headers.fetch("set-cookie")), auth.context.auth_cookies[:session_data].name)
      end

      Time.stub(:now, CREATED_AT + 120) do
        status, headers, _body = auth.api.get_session(headers: {"cookie" => initial_cookie}, as_response: true)

        assert_equal 200, status
        refute headers.key?("set-cookie")

        token_cookie = auth.context.auth_cookies[:session_token]
        session_token = endpoint_context(auth, cookie: initial_cookie).get_signed_cookie(token_cookie.name, auth.context.secret)
        stored = auth.context.internal_adapter.find_session(session_token).fetch(:session)
        assert_equal CREATED_AT + 86_400, stored.fetch("expiresAt")
      end
    end
  end

  private

  def build_auth(strategy:, database: :memory, refresh_cache: nil, update_age: SESSION_EXPIRES_IN)
    BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: database,
      email_and_password: {enabled: true, auto_sign_in: false},
      session: {
        expires_in: SESSION_EXPIRES_IN,
        update_age: update_age,
        cookie_cache: {
          enabled: true,
          strategy: strategy,
          max_age: CACHE_MAX_AGE,
          refresh_cache: refresh_cache
        }.compact
      }
    )
  end

  def create_user(auth, email)
    auth.api.sign_up_email(body: {email: email, password: "password123", name: "Remember Me User"})
  end

  def sign_in(auth, email, remember_me:)
    body = {email: email, password: "password123"}
    body[:rememberMe] = remember_me unless remember_me.nil?
    auth.api.sign_in_email(body: body, as_response: true)
  end

  def parsed_set_cookies(header)
    BetterAuth::Cookies.split_set_cookie_header(header).each_with_object({}) do |line, result|
      parsed = BetterAuth::Cookies.parse_set_cookie(line)
      result[parsed.fetch(:name)] = parsed
    end
  end

  def assert_session_cookie(cookie)
    refute cookie.fetch(:attributes).key?("max-age"), "expected #{cookie.fetch(:name)} to be session-only: #{cookie.fetch(:attributes)}"
    refute cookie.fetch(:attributes).key?("expires"), "expected #{cookie.fetch(:name)} to omit Expires: #{cookie.fetch(:attributes)}"
  end

  def assert_persistent_cookie(cookie, max_age)
    assert_equal max_age.to_s, cookie.fetch(:attributes).fetch("max-age")
    refute cookie.fetch(:attributes).key?("expires")
  end

  def assert_session_cookies(header, auth, persistent_for:)
    names = [
      auth.context.auth_cookies[:session_token].name,
      auth.context.auth_cookies[:session_data].name
    ]
    cookies = parsed_set_cookies(header)

    names.each do |name|
      cookie = cookies.fetch(name)
      if persistent_for
        assert_persistent_cookie(cookie, persistent_for)
      else
        assert_session_cookie(cookie)
      end
    end
  end

  def assert_mixed_session_cookies(header, auth, token_persistent_for:, data_persistent_for:)
    cookies = parsed_set_cookies(header)
    token_cookie = cookies.fetch(auth.context.auth_cookies[:session_token].name)
    data_cookie = cookies.fetch(auth.context.auth_cookies[:session_data].name)

    token_persistent_for ? assert_persistent_cookie(token_cookie, token_persistent_for) : assert_session_cookie(token_cookie)
    data_persistent_for ? assert_persistent_cookie(data_cookie, data_persistent_for) : assert_session_cookie(data_cookie)
  end

  def signed_cookie_value(auth, set_cookie, name)
    request = endpoint_context(auth, cookie: cookie_header(set_cookie))
    request.get_signed_cookie(name, auth.context.secret)
  end

  def decoded_cache(auth, strategy, set_cookie)
    secret = (strategy == "jwe") ? auth.context.secret_config : auth.context.secret
    BetterAuth::Cookies.get_cookie_cache(
      cookie_header(set_cookie),
      secret: secret,
      strategy: strategy,
      cookie_full_name: auth.context.auth_cookies[:session_data].name
    )
  end

  def assert_marker_not_embedded(data)
    refute data.key?("dontRememberMe")
    refute data.key?("dont_remember")
  end

  def signed_marker_header(auth)
    ctx = endpoint_context(auth)
    marker = auth.context.auth_cookies[:dont_remember]
    ctx.set_signed_cookie(marker.name, "true", auth.context.secret, marker.attributes)
    cookie_header(ctx.response_headers.fetch("set-cookie"))
  end

  def sample_session
    {
      session: {
        "id" => "session-1",
        "token" => "token-1",
        "userId" => "user-1",
        "createdAt" => CREATED_AT,
        "updatedAt" => CREATED_AT,
        "expiresAt" => CREATED_AT + SESSION_EXPIRES_IN
      },
      user: {
        "id" => "user-1",
        "email" => "remember@example.com",
        "name" => "Remember Me User",
        "emailVerified" => true,
        "createdAt" => CREATED_AT,
        "updatedAt" => CREATED_AT
      }
    }
  end

  def endpoint_context(auth, cookie: nil)
    BetterAuth::Endpoint::Context.new(
      path: "/get-session",
      method: "GET",
      query: {},
      body: {},
      params: {},
      headers: cookie ? {"cookie" => cookie} : {},
      context: auth.context
    )
  end

  def cookie_header(set_cookie)
    BetterAuth::Cookies.split_set_cookie_header(set_cookie).filter_map do |line|
      parsed = BetterAuth::Cookies.parse_set_cookie(line)
      "#{parsed.fetch(:name)}=#{parsed.fetch(:value)}"
    end.join("; ")
  end

  def without_cookie(header, excluded_name)
    BetterAuth::Cookies.parse_cookies(header).reject { |name, _value| name == excluded_name }.map do |name, value|
      "#{name}=#{value}"
    end.join("; ")
  end
end
