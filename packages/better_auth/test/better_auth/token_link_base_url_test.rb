# frozen_string_literal: true

require "json"
require "stringio"
require "uri"
require_relative "../test_helper"

class BetterAuthTokenLinkBaseURLTest < Minitest::Test
  SECRET = "token-link-base-url-secret-with-enough-entropy"

  def test_production_rejects_request_inferred_hosts_before_user_lookup_branches
    with_env(production_env) do
      sent = []
      auth = build_auth(send_reset_password: ->(data, _request = nil) { sent << data })
      auth.context.internal_adapter.create_user(email: "existing@example.com", name: "Existing", emailVerified: true)

      existing = request_password_reset(auth, "existing@example.com", host: "attacker.example")
      missing = request_password_reset(auth, "missing@example.com", host: "attacker.example")

      [existing, missing].each do |status, body|
        assert_equal 500, status
        assert_equal "TOKEN_LINK_BASE_URL_NOT_CONFIGURED", body.fetch("code")
      end
      assert_empty sent
      assert_empty auth.context.adapter.find_many(model: "verification")
    end
  end

  def test_production_change_email_rejects_existing_and_missing_targets_before_sending
    with_env(production_env) do
      sent = []
      auth = build_full_token_link_auth(sent)
      user = auth.context.internal_adapter.create_user(email: "owner@example.com", name: "Owner", emailVerified: true)
      auth.context.internal_adapter.create_user(email: "taken@example.com", name: "Taken", emailVerified: true)
      cookie = session_cookie(auth, user)

      missing = post(auth, "/api/auth/change-email", {newEmail: "available@example.com"}, host: "attacker.example", cookie: cookie)
      existing = post(auth, "/api/auth/change-email", {newEmail: "taken@example.com"}, host: "attacker.example", cookie: cookie)

      [missing, existing].each do |status, body|
        assert_equal 500, status
        assert_equal "TOKEN_LINK_BASE_URL_NOT_CONFIGURED", body.fetch("code")
      end
      assert_empty sent
      assert_empty auth.context.adapter.find_many(model: "verification")
    end
  end

  def test_every_shipped_token_link_route_uses_the_production_guard
    with_env(production_env) do
      sent = []
      auth = build_full_token_link_auth(sent)
      user = auth.context.internal_adapter.create_user(email: "guarded@example.com", name: "Guarded", emailVerified: true)
      cookie = session_cookie(auth, user)
      confirmation_token = BetterAuth::Crypto.sign_jwt(
        {
          "email" => user["email"],
          "updateTo" => "guarded-new@example.com",
          "requestType" => "change-email-confirmation"
        },
        SECRET,
        expires_in: 3600
      )

      responses = {
        password_reset: post(auth, "/api/auth/request-password-reset", {email: user["email"]}, host: "attacker.example"),
        sign_up_verification: post(auth, "/api/auth/sign-up/email", {email: "new@example.com", password: "password123", name: "New"}, host: "attacker.example"),
        sign_in_verification: post(auth, "/api/auth/sign-in/email", {email: user["email"], password: "password123"}, host: "attacker.example"),
        username_sign_in_verification: post(auth, "/api/auth/sign-in/username", {username: "guarded", password: "password123"}, host: "attacker.example"),
        explicit_verification: post(auth, "/api/auth/send-verification-email", {email: user["email"]}, host: "attacker.example"),
        delete_user: post(auth, "/api/auth/delete-user", {}, host: "attacker.example", cookie: cookie),
        change_email: post(auth, "/api/auth/change-email", {newEmail: "other@example.com"}, host: "attacker.example", cookie: cookie),
        follow_up_change_email: get(auth, "/api/auth/verify-email", {token: confirmation_token}, host: "attacker.example"),
        magic_link: post(auth, "/api/auth/sign-in/magic-link", {email: user["email"]}, host: "attacker.example")
      }

      responses.each do |route, (status, body)|
        assert_equal 500, status, route.to_s
        assert_equal "TOKEN_LINK_BASE_URL_NOT_CONFIGURED", body.fetch("code"), route.to_s
      end
      assert_empty sent
      assert_nil auth.context.internal_adapter.find_user_by_email("new@example.com")
      assert_empty auth.context.adapter.find_many(model: "verification")
    end
  end

  def test_production_accepts_static_base_url_without_trusting_request_host
    with_env(production_env) do
      sent = []
      auth = build_auth(
        base_url: "https://auth.example.com",
        send_reset_password: ->(data, _request = nil) { sent << data }
      )
      auth.context.internal_adapter.create_user(email: "static@example.com", name: "Static", emailVerified: true)

      status, = request_password_reset(auth, "static@example.com", host: "attacker.example")

      assert_equal 200, status
      assert_equal 1, sent.length
      assert_match(%r{\Ahttps://auth\.example\.com/api/auth/reset-password/}, sent.first.fetch(:url))
    end
  end

  def test_production_accepts_environment_base_url
    with_env(production_env.merge("BETTER_AUTH_URL" => "https://env-auth.example.com")) do
      sent = []
      auth = build_auth(send_reset_password: ->(data, _request = nil) { sent << data })
      auth.context.internal_adapter.create_user(email: "env@example.com", name: "Env", emailVerified: true)

      status, = request_password_reset(auth, "env@example.com", host: "attacker.example")

      assert_equal 200, status
      assert_equal 1, sent.length
      assert_match(%r{\Ahttps://env-auth\.example\.com/api/auth/reset-password/}, sent.first.fetch(:url))
    end
  end

  def test_production_accepts_dynamic_allowed_host_base_url
    with_env(production_env) do
      sent = []
      auth = build_auth(
        base_url: {allowed_hosts: ["tenant.example"], protocol: "https"},
        send_reset_password: ->(data, _request = nil) { sent << data }
      )
      auth.context.internal_adapter.create_user(email: "dynamic@example.com", name: "Dynamic", emailVerified: true)

      status, = request_password_reset(auth, "dynamic@example.com", host: "tenant.example")

      assert_equal 200, status
      assert_equal 1, sent.length
      assert_match(%r{\Ahttps://tenant\.example/api/auth/reset-password/}, sent.first.fetch(:url))
    end
  end

  def test_development_and_test_preserve_request_inferred_token_links
    %w[development test].each do |environment|
      with_env(non_production_env(environment)) do
        sent = []
        auth = build_auth(send_reset_password: ->(data, _request = nil) { sent << data })
        email = "#{environment}@example.com"
        host = "#{environment}.example"
        auth.context.internal_adapter.create_user(email: email, name: environment.capitalize, emailVerified: true)

        status, = request_password_reset(auth, email, host: host)

        assert_equal 200, status
        assert_equal 1, sent.length
        assert_match(%r{\Ahttp://#{environment}\.example/api/auth/reset-password/}, sent.first.fetch(:url))
      end
    end
  end

  def test_explicit_unsafe_opt_out_preserves_production_request_inference
    with_env(production_env) do
      sent = []
      auth = build_auth(
        advanced: {allow_unsafe_token_link_base_url_inference: true},
        send_reset_password: ->(data, _request = nil) { sent << data }
      )
      auth.context.internal_adapter.create_user(email: "legacy@example.com", name: "Legacy", emailVerified: true)

      status, = request_password_reset(auth, "legacy@example.com", host: "legacy.example")

      assert_equal 200, status
      assert_equal 1, sent.length
      assert_match(%r{\Ahttp://legacy\.example/api/auth/reset-password/}, sent.first.fetch(:url))
    end
  end

  private

  def build_auth(send_reset_password:, base_url: nil, advanced: nil)
    options = {
      secret: SECRET,
      database: :memory,
      email_and_password: {
        enabled: true,
        send_reset_password: send_reset_password
      }
    }
    options[:base_url] = base_url if base_url
    options[:advanced] = advanced if advanced
    BetterAuth.auth(options)
  end

  def build_full_token_link_auth(sent)
    sender = ->(data, _request = nil) { sent << data }
    BetterAuth.auth(
      secret: SECRET,
      database: :memory,
      email_and_password: {
        enabled: true,
        require_email_verification: true,
        send_reset_password: sender
      },
      email_verification: {
        send_on_sign_up: true,
        send_on_sign_in: true,
        send_verification_email: sender
      },
      user: {
        change_email: {
          enabled: true,
          send_change_email_confirmation: sender
        },
        delete_user: {
          enabled: true,
          send_delete_account_verification: sender
        }
      },
      plugins: [
        BetterAuth::Plugins.magic_link(send_magic_link: sender),
        BetterAuth::Plugins.username
      ]
    )
  end

  def request_password_reset(auth, email, host:)
    post(auth, "/api/auth/request-password-reset", {email: email}, host: host)
  end

  def post(auth, path, body, host:, cookie: nil)
    status, _headers, response_body = auth.call(rack_env("POST", path, body: body, host: host, cookie: cookie))
    [status, JSON.parse(response_body.join)]
  end

  def get(auth, path, query, host:)
    status, _headers, response_body = auth.call(rack_env("GET", path, body: {}, host: host, query: URI.encode_www_form(query)))
    [status, JSON.parse(response_body.join)]
  end

  def session_cookie(auth, user)
    session = auth.context.internal_adapter.create_session(user["id"])
    name = auth.context.auth_cookies[:session_token].name
    signature = BetterAuth::Crypto.hmac_signature(session["token"], SECRET, encoding: :base64url)
    "#{name}=#{session["token"]}.#{signature}"
  end

  def rack_env(method, path, body:, host:, cookie: nil, query: "")
    payload = JSON.generate(body)
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => query,
      "SERVER_NAME" => host,
      "SERVER_PORT" => "80",
      "REMOTE_ADDR" => "127.0.0.1",
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(payload),
      "CONTENT_TYPE" => "application/json",
      "CONTENT_LENGTH" => payload.bytesize.to_s,
      "HTTP_HOST" => host,
      "HTTP_COOKIE" => cookie
    }.compact
    env["HTTP_ORIGIN"] = "http://#{host}" if cookie
    env
  end

  def production_env
    {
      "RACK_ENV" => "production",
      "RAILS_ENV" => nil,
      "APP_ENV" => nil,
      "BETTER_AUTH_URL" => nil,
      "BASE_URL" => nil
    }
  end

  def non_production_env(environment)
    production_env.merge("RACK_ENV" => environment)
  end

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV[key]] }
    values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
