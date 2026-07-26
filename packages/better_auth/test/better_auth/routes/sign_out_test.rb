# frozen_string_literal: true

require "json"
require_relative "../../test_helper"

class BetterAuthRoutesSignOutTest < Minitest::Test
  SECRET = "phase-five-secret-with-enough-entropy-123"

  def test_sign_out_without_session_still_returns_success_and_clears_cookies
    auth = BetterAuth.auth(base_url: "http://localhost:3000", secret: SECRET)

    status, headers, body = auth.api.sign_out(as_response: true)

    assert_equal 200, status
    assert_equal({"success" => true}, JSON.parse(body.join))
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token="
    assert_includes headers.fetch("set-cookie"), "Max-Age=0"
  end

  def test_sign_out_deletes_session_clears_cookies_and_runs_delete_hook
    deleted = []
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      email_and_password: {enabled: true},
      database: :memory,
      database_hooks: {
        session: {
          delete: {
            after: ->(session, _context) { deleted << session["token"] }
          }
        }
      }
    )
    _status, sign_up_headers, _body = auth.api.sign_up_email(
      body: {email: "sign-out-route@example.com", password: "password123", name: "Sign Out"},
      as_response: true
    )
    cookie = cookie_header(sign_up_headers.fetch("set-cookie"))
    session = auth.api.get_session(headers: {"cookie" => cookie})

    status, headers, body = auth.api.sign_out(headers: {"cookie" => cookie}, as_response: true)

    assert_equal 200, status
    assert_equal({"success" => true}, JSON.parse(body.join))
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token="
    assert_includes headers.fetch("set-cookie"), "Max-Age=0"
    assert_includes deleted, session[:session]["token"]
    assert_nil auth.context.internal_adapter.find_session(session[:session]["token"])
  end

  def test_sign_out_clears_session_cache_and_account_cookies_when_enabled
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      email_and_password: {enabled: true},
      database: :memory,
      account: {store_account_cookie: true},
      session: {cookie_cache: {enabled: true, strategy: "jwe", max_age: 300}},
      social_providers: {
        github: {
          client_id: "id",
          client_secret: "secret",
          refresh_access_token: ->(_refresh_token) {
            {accessToken: "fresh-access", refreshToken: "fresh-refresh", accessTokenExpiresAt: Time.now + 3600}
          }
        }
      }
    )
    _status, sign_up_headers, _body = auth.api.sign_up_email(
      body: {email: "sign-out-cookies@example.com", password: "password123", name: "Sign Out Cookies"},
      as_response: true
    )
    cookie = cookie_header(sign_up_headers.fetch("set-cookie"))
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    auth.context.internal_adapter.create_account(
      userId: user_id,
      providerId: "github",
      accountId: "gh-sign-out",
      accessToken: "stored-access",
      refreshToken: "stored-refresh",
      accessTokenExpiresAt: Time.now - 60,
      scope: "repo"
    )
    _status, token_headers, _body = auth.api.get_access_token(
      headers: {"cookie" => cookie},
      body: {providerId: "github", accountId: "gh-sign-out"},
      as_response: true
    )
    cookie = [cookie, cookie_header(token_headers.fetch("set-cookie"))].join("; ")

    _status, headers, _body = auth.api.sign_out(headers: {"cookie" => cookie}, as_response: true)
    set_cookie = headers.fetch("set-cookie")

    assert_includes set_cookie, "better-auth.session_token="
    assert_includes set_cookie, "better-auth.session_data="
    assert_includes set_cookie, "better-auth.account_data="
    assert_includes set_cookie, "Max-Age=0"
  end

  def test_sign_out_succeeds_and_clears_cookies_when_session_deletion_fails
    deletion_error = RuntimeError.new("database unavailable")
    log_entries = []
    failing_adapter = Class.new(BetterAuth::Adapters::Memory) do
      define_method(:delete) do |model:, where:|
        raise deletion_error if model.to_s == "session"

        super(model: model, where: where)
      end
    end
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      email_and_password: {enabled: true},
      database: ->(options) { failing_adapter.new(options) },
      account: {store_account_cookie: true},
      session: {cookie_cache: {enabled: true, strategy: "jwe", max_age: 300}},
      logger: ->(level, message) { log_entries << [level, message] }
    )
    _status, sign_up_headers, _body = auth.api.sign_up_email(
      body: {email: "sign-out-failure@example.com", password: "password123", name: "Sign Out Failure"},
      as_response: true
    )
    cookie = [cookie_header(sign_up_headers.fetch("set-cookie")), "better-auth.account_data=stale"].join("; ")

    2.times do
      status, headers, body = auth.api.sign_out(headers: {"cookie" => cookie}, as_response: true)

      assert_equal 200, status
      assert_equal({"success" => true}, JSON.parse(body.join))
      %w[better-auth.session_token better-auth.session_data better-auth.account_data].each do |name|
        assert headers.fetch("set-cookie").lines.any? { |line| line.start_with?("#{name}=") && line.include?("Max-Age=0") }
      end
    end
    assert_equal Array.new(2) { [:error, "Failed to delete session from database: RuntimeError: database unavailable"] }, log_entries
  end

  private

  def cookie_header(set_cookie)
    set_cookie.lines.map { |line| line.split(";").first }.join("; ")
  end
end
