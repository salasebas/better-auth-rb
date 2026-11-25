# frozen_string_literal: true

require "json"
require_relative "../../test_helper"

class BetterAuthRoutesSessionTest < Minitest::Test
  SECRET = "phase-five-secret-with-enough-entropy-123"

  def test_get_session_returns_nil_without_cookie
    auth = build_auth

    assert_nil auth.api.get_session
  end

  def test_get_session_endpoint_accepts_get_and_post_like_upstream
    auth = build_auth

    assert_equal ["GET", "POST"], auth.api.endpoints.fetch(:get_session).methods
  end

  def test_get_session_post_requires_deferred_refresh
    auth = build_auth
    cookie = sign_up_cookie(auth, email: "post-session@example.com")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.get_session(headers: {"cookie" => cookie}, method: "POST")
    end

    assert_equal 405, error.status_code
    assert_equal "METHOD_NOT_ALLOWED_DEFER_SESSION_REQUIRED", error.code
    assert_equal BetterAuth::BASE_ERROR_CODES["METHOD_NOT_ALLOWED_DEFER_SESSION_REQUIRED"], error.message
  end

  def test_update_session_requires_body_object_like_upstream
    auth = build_auth(
      session: {
        additional_fields: {
          activeOrganizationId: {type: "string", required: false}
        }
      }
    )
    cookie = sign_up_cookie(auth, email: "session-body-object@example.com")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.update_session(headers: {"cookie" => cookie}, body: ["not-object"])
    end

    assert_equal 400, error.status_code
    assert_equal "BODY_MUST_BE_AN_OBJECT", error.code
    assert_equal BetterAuth::BASE_ERROR_CODES["BODY_MUST_BE_AN_OBJECT"], error.message
  end

  def test_update_session_rejects_plugin_authority_fields
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.organization(
          teams: {enabled: true},
          schema: {session: {fields: {activeTeamId: "current_team"}}}
        ),
        BetterAuth::Plugins.admin(schema: {session: {fields: {impersonatedBy: "acting_admin"}}})
      ],
      session: {additional_fields: {activeOrganizationId: {type: "string", required: false}}}
    )
    cookie = sign_up_cookie(auth, email: "plugin-session-fields@example.com")

    %w[activeOrganizationId activeTeamId impersonatedBy].each do |field|
      error = assert_raises(BetterAuth::APIError) do
        auth.api.update_session(headers: {"cookie" => cookie}, body: {field => "client-value"})
      end
      assert_equal 400, error.status_code
      assert_equal "FIELD_NOT_ALLOWED", error.code
      assert_equal "#{field} is not allowed to be set", error.message
    end
  end

  def test_get_session_deferred_get_reports_needs_refresh_without_updating_session
    auth = build_auth(session: {defer_session_refresh: true, update_age: 60, expires_in: 120, cookie_cache: {enabled: false}})
    cookie = sign_up_cookie(auth, email: "deferred-session@example.com")
    session = auth.api.get_session(headers: {"cookie" => cookie}, method: "POST")
    stale_updated_at = Time.now - 61
    auth.context.adapter.update(
      model: "session",
      where: [{field: "token", value: session[:session]["token"]}],
      update: {updatedAt: stale_updated_at, expiresAt: Time.now + 30}
    )

    result = auth.api.get_session(headers: {"cookie" => cookie})
    stored = auth.context.adapter.find_one(model: "session", where: [{field: "token", value: session[:session]["token"]}])

    assert_equal true, result[:needsRefresh]
    assert_in_delta stale_updated_at.to_i, stored.fetch("updatedAt").to_i, 1
  end

  def test_get_session_deferred_post_refreshes_stale_session
    auth = build_auth(session: {defer_session_refresh: true, update_age: 60, expires_in: 120, cookie_cache: {enabled: false}})
    cookie = sign_up_cookie(auth, email: "deferred-post-refresh@example.com")
    session = auth.api.get_session(headers: {"cookie" => cookie}, method: "POST")
    stale_updated_at = Time.now - 61
    auth.context.adapter.update(
      model: "session",
      where: [{field: "token", value: session[:session]["token"]}],
      update: {updatedAt: stale_updated_at, expiresAt: Time.now + 30}
    )

    result = auth.api.get_session(headers: {"cookie" => cookie}, method: "POST")
    stored = auth.context.adapter.find_one(model: "session", where: [{field: "token", value: session[:session]["token"]}])

    assert_equal "deferred-post-refresh@example.com", result[:user]["email"]
    refute result.key?(:needsRefresh)
    assert_operator stored.fetch("updatedAt"), :>, stale_updated_at
  end

  def test_deferred_get_only_reports_needs_refresh_for_database_reads_that_allow_refresh
    auth = build_auth(session: {defer_session_refresh: true, cookie_cache: {enabled: true}})
    email = "deferred-cached@example.com"
    cookie = sign_up_cookie(auth, email: email)
    headers = {"cookie" => cookie}

    refute auth.api.get_session(headers: headers).key?(:needsRefresh)
    assert_equal false, auth.api.get_session(headers: headers, query: {disableCookieCache: true})[:needsRefresh]
    refute auth.api.get_session(headers: headers, query: {disableCookieCache: true, disableRefresh: true}).key?(:needsRefresh)

    browser_cookie = sign_in_cookie(auth, email: email, remember_me: false)
    result = auth.api.get_session(headers: {"cookie" => browser_cookie}, query: {disableCookieCache: true})
    refute result.key?(:needsRefresh)
  end

  def test_get_session_evaluates_deferred_refresh_after_a_hook_reads_the_session
    hooks = {before: lambda do |ctx|
      BetterAuth::Routes.current_session(ctx) if ctx.path == "/get-session"
      nil
    end}
    auth = build_auth(hooks: hooks, session: {defer_session_refresh: true, update_age: 60, expires_in: 120})
    cookie = sign_up_cookie(auth, email: "deferred-hook@example.com")
    headers = {"cookie" => cookie}
    token = auth.api.get_session(headers: headers).dig(:session, "token")
    expires_at = Time.now + 30
    auth.context.internal_adapter.update_session(token, "expiresAt" => expires_at)

    assert_equal true, auth.api.get_session(headers: headers)[:needsRefresh]
    assert_equal expires_at, auth.context.internal_adapter.find_session(token).dig(:session, "expiresAt")

    result = auth.api.get_session(headers: headers, method: "POST")
    refute result.key?(:needsRefresh)
    assert_operator auth.context.internal_adapter.find_session(token).dig(:session, "expiresAt"), :>, expires_at
  end

  def test_get_session_returns_current_session_and_user
    auth = build_auth
    cookie = sign_up_cookie(auth, email: "session@example.com")

    result = auth.api.get_session(headers: {"cookie" => cookie})

    assert_equal "session@example.com", result[:user]["email"]
    assert_match(/\A[0-9a-f]{32}\z/, result[:session]["token"])
    assert_equal result[:user]["id"], result[:session]["userId"]
  end

  def test_sign_in_sets_session_cookie_attributes
    auth = build_auth
    sign_up_cookie(auth, email: "cookie-attributes@example.com")

    status, headers, _body = auth.api.sign_in_email(
      body: {email: "cookie-attributes@example.com", password: "password123"},
      as_response: true
    )

    assert_equal 200, status
    session_cookie = headers.fetch("set-cookie").lines.find { |line| line.include?("better-auth.session_token=") }
    assert_includes session_cookie, "Max-Age=604800"
    assert_includes session_cookie, "Path=/"
    assert_includes session_cookie, "SameSite=Lax"
    assert_includes session_cookie, "HttpOnly"
  end

  def test_get_session_refreshes_database_session_when_update_age_is_reached
    auth = build_auth(session: {update_age: 60, expires_in: 120, cookie_cache: {enabled: true}})
    cookie = sign_up_cookie(auth, email: "refresh-age@example.com")
    session = auth.api.get_session(headers: {"cookie" => cookie})
    original_expires_at = session[:session]["expiresAt"]

    auth.context.adapter.update(
      model: "session",
      where: [{field: "token", value: session[:session]["token"]}],
      update: {updatedAt: Time.now, expiresAt: Time.now + 30}
    )
    stale_expires_at = auth.context.adapter.find_one(model: "session", where: [{field: "token", value: session[:session]["token"]}]).fetch("expiresAt")

    status, headers, body = auth.api.get_session(headers: {"cookie" => cookie}, query: {disableCookieCache: true}, as_response: true)
    refreshed = JSON.parse(body.join)

    assert_equal 200, status
    assert_operator Time.parse(refreshed.fetch("session").fetch("expiresAt")), :>, stale_expires_at
    assert_operator Time.parse(refreshed.fetch("session").fetch("expiresAt")), :>=, Time.parse(original_expires_at.to_s)
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token="
    assert_includes headers.fetch("set-cookie"), "Max-Age=120"
    assert_equal 1, headers.fetch("set-cookie").lines.count { |line| line.start_with?("better-auth.session_data=") }
  end

  def test_get_session_disable_refresh_leaves_stale_database_session_unchanged
    auth = build_auth(session: {update_age: 60, expires_in: 120, cookie_cache: {enabled: true}})
    cookie = sign_up_cookie(auth, email: "disable-refresh@example.com")
    session = auth.api.get_session(headers: {"cookie" => cookie})
    stale_expires_at = Time.now + 30
    stale_updated_at = Time.now - 61
    auth.context.adapter.update(
      model: "session",
      where: [{field: "token", value: session[:session]["token"]}],
      update: {updatedAt: stale_updated_at, expiresAt: stale_expires_at}
    )

    status, headers, body = auth.api.get_session(
      headers: {"cookie" => cookie},
      query: {disableCookieCache: true, disableRefresh: true},
      as_response: true
    )
    result = JSON.parse(body.join)
    stored = auth.context.adapter.find_one(model: "session", where: [{field: "token", value: session[:session]["token"]}])

    assert_equal 200, status
    refute headers.key?("set-cookie")
    assert_in_delta stale_expires_at.to_i, Time.parse(result.fetch("session").fetch("expiresAt")).to_i, 1
    assert_in_delta stale_updated_at.to_i, stored.fetch("updatedAt").to_i, 1
  end

  def test_get_session_respects_disable_session_refresh_without_defer
    auth = build_auth(session: {update_age: 0, disable_session_refresh: true, cookie_cache: {enabled: true}})
    cookie = sign_up_cookie(auth, email: "disabled-session-refresh@example.com")
    _status, headers, _body = auth.api.get_session(headers: {"cookie" => cookie}, query: {disableCookieCache: true}, as_response: true)

    assert_includes headers.fetch("set-cookie"), "better-auth.session_data="
    refute_includes headers.fetch("set-cookie"), "better-auth.session_token="
  end

  def test_request_state_skips_session_refresh_only_for_the_current_request
    hooks = {before: lambda do |ctx|
      BetterAuth::Session.set_should_skip_session_refresh(true) if ctx.headers["x-skip-refresh"] == "true"
      nil
    end}
    auth = build_auth(hooks: hooks, session: {update_age: 0, cookie_cache: {enabled: false}})
    cookie = sign_up_cookie(auth, email: "skip-session-refresh@example.com")

    _status, skipped, _body = auth.api.get_session(headers: {"cookie" => cookie, "x-skip-refresh" => "true"}, as_response: true)
    _status, refreshed, _body = auth.api.get_session(headers: {"cookie" => cookie}, as_response: true)

    refute skipped.key?("set-cookie")
    assert_includes refreshed.fetch("set-cookie"), "better-auth.session_token="
  end

  def test_get_session_with_expired_database_session_returns_null_and_clears_cookie
    auth = build_auth(session: {cookie_cache: {enabled: false}})
    cookie = sign_up_cookie(auth, email: "expired-session@example.com")
    session = auth.api.get_session(headers: {"cookie" => cookie})
    auth.context.adapter.update(
      model: "session",
      where: [{field: "token", value: session[:session]["token"]}],
      update: {expiresAt: Time.now - 1}
    )

    status, headers, body = auth.api.get_session(headers: {"cookie" => cookie}, as_response: true)

    assert_equal 200, status
    assert_nil JSON.parse(body.join)
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token="
    assert_includes headers.fetch("set-cookie"), "Max-Age=0"
    assert_nil auth.context.internal_adapter.find_session(session[:session]["token"])
  end

  def test_deferred_refresh_leaves_expired_session_cleanup_to_post
    auth = build_auth(session: {defer_session_refresh: true})
    cookie = sign_up_cookie(auth, email: "deferred-expired@example.com")
    headers = {"cookie" => cookie}
    token = auth.api.get_session(headers: headers).dig(:session, "token")
    auth.context.internal_adapter.update_session(token, "expiresAt" => Time.now - 1)

    assert_nil auth.api.get_session(headers: headers)
    refute_nil auth.context.internal_adapter.find_session(token)

    assert_nil auth.api.get_session(headers: headers, method: "POST")
    assert_nil auth.context.internal_adapter.find_session(token)
  end

  def test_get_session_disable_cookie_cache_reads_authoritative_database
    auth = build_auth(session: {cookie_cache: {enabled: true, strategy: "jwe", max_age: 300}})
    cookie = sign_up_cookie(auth, email: "disable-cache@example.com")
    session = auth.api.get_session(headers: {"cookie" => cookie})
    auth.context.adapter.update(
      model: "user",
      where: [{field: "id", value: session[:user]["id"]}],
      update: {name: "Authoritative Name"}
    )

    cached = auth.api.get_session(headers: {"cookie" => cookie})
    authoritative = auth.api.get_session(headers: {"cookie" => cookie}, query: {disableCookieCache: true})

    refute_equal "Authoritative Name", cached[:user]["name"]
    assert_equal "Authoritative Name", authoritative[:user]["name"]
  end

  def test_get_session_with_tampered_cache_falls_back_to_database_and_refreshes_cache
    auth = build_auth(session: {cookie_cache: {enabled: true, strategy: "jwe", max_age: 300}})
    cookie = sign_up_cookie(auth, email: "tampered-cache@example.com")
    tampered = cookie.gsub(/better-auth\.session_data=[^; ]+/, "better-auth.session_data=invalid")

    status, headers, body = auth.api.get_session(headers: {"cookie" => tampered}, as_response: true)

    assert_equal 200, status
    assert_equal "tampered-cache@example.com", JSON.parse(body.join).fetch("user").fetch("email")
    assert_includes headers.fetch("set-cookie"), "better-auth.session_data="
  end

  def test_get_session_expires_invalid_cache_even_when_refresh_is_disabled
    auth = build_auth(session: {cookie_cache: {enabled: true, strategy: "jwe"}})
    cookie = sign_up_cookie(auth, email: "invalid-cache-no-refresh@example.com")
    tampered = cookie.sub(/better-auth\.session_data=[^; ]+/, "better-auth.session_data=invalid")

    _status, headers, body = auth.api.get_session(headers: {"cookie" => tampered}, query: {disableRefresh: true}, as_response: true)

    assert_equal "invalid-cache-no-refresh@example.com", JSON.parse(body.join).dig("user", "email")
    assert_match(/\Abetter-auth\.session_data=;.*Max-Age=0/, headers.fetch("set-cookie"))
  end

  def test_cookie_cache_version_mismatch_falls_back_to_authoritative_session
    auth = build_auth(session: {cookie_cache: {enabled: true, strategy: "jwe", version: "2", max_age: 300}})
    cookie = sign_up_cookie(auth, email: "version-cache@example.com")
    session = auth.api.get_session(headers: {"cookie" => cookie})
    auth.context.adapter.update(
      model: "user",
      where: [{field: "id", value: session[:user]["id"]}],
      update: {name: "Fresh User"}
    )
    auth.context.session_config[:cookie_cache] = auth.context.session_config[:cookie_cache].except(:version)

    result = auth.api.get_session(headers: {"cookie" => cookie})

    assert_equal "Fresh User", result[:user]["name"]
  end

  def test_empty_cache_version_uses_the_default_on_write_and_read
    auth = build_auth(session: {cookie_cache: {enabled: true, version: ""}})
    email = "empty-cache-version@example.com"
    cookie = sign_up_cookie(auth, email: email)
    payload = BetterAuth::Cookies.get_cookie_cache(cookie, secret: SECRET)

    assert_equal "1", payload.fetch("version")
    _, headers, body = auth.api.get_session(headers: {"cookie" => cookie}, as_response: true)
    assert_equal email, JSON.parse(body.join).dig("user", "email")
    refute headers.key?("set-cookie")
  end

  def test_stateless_cookie_cache_refresh_uses_configured_max_ages_with_strict_boundary
    %w[compact jwt jwe].each do |strategy|
      fixture = stateless_cookie_cache_fixture(
        strategy: strategy,
        refresh_cache: {update_age: 60},
        email: "#{strategy}-refresh-boundary@example.com",
        expires_in: 300
      )

      [61, 240].each do |elapsed_seconds|
        status, headers, result = stateless_session_response(fixture, elapsed_seconds)

        assert_equal 200, status, strategy
        assert_equal fixture[:original][:session], result.fetch("session"), strategy
        assert_cookie_refresh_headers headers, expected: false, message: "#{strategy} at elapsed #{elapsed_seconds}"
      end

      BetterAuth::RequestState.run do
        BetterAuth::Session.set_should_skip_session_refresh(true)
        _, skipped_headers, _ = stateless_session_response(fixture, 241)
        assert_cookie_refresh_headers skipped_headers, expected: false, message: strategy
      end

      status, headers, result = stateless_session_response(fixture, 241)

      assert_equal 200, status, strategy
      assert_equal fixture[:original][:session], result.fetch("session"), strategy
      assert_equal fixture[:original][:session]["expiresAt"], result.fetch("session").fetch("expiresAt"), strategy
      refresh_headers = assert_cookie_refresh_headers headers, expected: true, message: "#{strategy} below threshold"
      assert_includes refresh_headers.fetch(:session_data), "Max-Age=300", strategy
      assert_includes refresh_headers.fetch(:session_token), "Max-Age=300", strategy

      _status, _, expired = Time.stub(:now, fixture[:issued_at] + 301) do
        fixture[:auth].api.get_session(headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))}, as_response: true)
      end
      assert_nil JSON.parse(expired.join), strategy
    end
  end

  def test_get_session_expires_jwe_cache_at_its_own_deadline
    auth = build_auth(session: {expires_in: 600, cookie_cache: {enabled: true, strategy: "jwe", max_age: 60}})
    issued_at = Time.utc(2026, 7, 12, 12, 0, 0)
    email = "expired-cache-window@example.com"
    cookie = Time.stub(:now, issued_at) { sign_up_cookie(auth, email: email) }

    _, headers, body = Time.stub(:now, issued_at + 61) do
      auth.api.get_session(headers: {"cookie" => cookie}, query: {disableRefresh: true}, as_response: true)
    end

    assert_equal email, JSON.parse(body.join).dig("user", "email")
    assert_match(/\Abetter-auth\.session_data=;.*Max-Age=0/, headers.fetch("set-cookie"))
  end

  def test_stateless_cookie_cache_refresh_true_and_empty_config_derive_twenty_percent_of_effective_max_age
    {true_config: true, empty_config: {}}.each do |name, refresh_cache|
      fixture = stateless_cookie_cache_fixture(
        strategy: "compact",
        refresh_cache: refresh_cache,
        email: "#{name}-refresh@example.com",
        max_age: nil,
        expires_in: 305
      )

      _status, equality_headers, equality_result = stateless_session_response(fixture, 244)
      assert_equal fixture[:original][:session], equality_result.fetch("session")
      assert_cookie_refresh_headers equality_headers, expected: false, message: name

      _status, below_headers, below_result = stateless_session_response(fixture, 245)
      assert_equal fixture[:original][:session], below_result.fetch("session")
      assert_cookie_refresh_headers below_headers, expected: true, message: name
    end
  end

  def test_stateless_cookie_cache_refresh_preserves_fractional_custom_update_age
    fixture = stateless_cookie_cache_fixture(
      strategy: "compact",
      refresh_cache: {update_age: 1.5},
      email: "fractional-refresh@example.com",
      max_age: 10
    )

    _status, equality_headers, equality_result = stateless_session_response(fixture, Rational(17, 2))
    assert_equal fixture[:original][:session], equality_result.fetch("session")
    assert_cookie_refresh_headers equality_headers, expected: false, message: "1.5 seconds remaining"

    _status, below_headers, below_result = stateless_session_response(fixture, Rational(44, 5))
    assert_equal fixture[:original][:session], below_result.fetch("session")
    assert_cookie_refresh_headers below_headers, expected: true, message: "1.2 seconds remaining"
  end

  def test_stateless_cookie_cache_refresh_uses_implicit_defaults_with_strict_boundary
    issued_at = Time.utc(2026, 7, 12, 12, 0, 0)
    auth = build_auth(database: nil)
    cookie = Time.stub(:now, issued_at) { sign_up_cookie(auth, email: "default-refresh@example.com") }
    original = Time.stub(:now, issued_at) { auth.api.get_session(headers: {"cookie" => cookie}) }
    auth.context.internal_adapter.delete_session(original[:session]["token"])
    fixture = {auth: auth, cookie: cookie, issued_at: issued_at, original: original}

    _status, equality_headers, equality_result = stateless_session_response(fixture, 483_840)
    assert_equal original[:session], equality_result.fetch("session")
    assert_cookie_refresh_headers equality_headers, expected: false, message: "implicit default equality"

    _status, below_headers, below_result = stateless_session_response(fixture, 483_841)
    assert_equal original[:session], below_result.fetch("session")
    assert_cookie_refresh_headers below_headers, expected: true, message: "implicit default below threshold"
  end

  def test_stateless_cookie_cache_refresh_remember_me_false_uses_same_threshold
    fixture = stateless_cookie_cache_fixture(
      strategy: "jwe",
      refresh_cache: {update_age: 60},
      email: "remember-me-threshold@example.com",
      remember_me: false
    )

    _status, equality_headers, equality_result = stateless_session_response(fixture, 240)
    assert_equal fixture[:original][:session], equality_result.fetch("session")
    assert_cookie_refresh_headers equality_headers, expected: false, message: "remember me equality"

    _status, below_headers, below_result = stateless_session_response(fixture, 241)
    assert_equal fixture[:original][:session], below_result.fetch("session")
    assert_cookie_refresh_headers below_headers, expected: true, message: "remember me below threshold"
  end

  def test_stateless_cookie_cache_refresh_zero_and_false_do_not_refresh_before_expiry
    {zero: {update_age: 0}, disabled: false}.each do |name, refresh_cache|
      fixture = stateless_cookie_cache_fixture(
        strategy: "jwt",
        refresh_cache: refresh_cache,
        email: "#{name}-refresh@example.com",
        expires_in: 600
      )

      status, headers, result = stateless_session_response(fixture, 299)

      assert_equal 200, status, name
      assert_equal fixture[:original][:session], result.fetch("session"), name
      assert_cookie_refresh_headers headers, expected: false, message: name
    end
  end

  def test_zero_cache_max_age_uses_the_default_cache_window_and_refresh_threshold
    fixture = stateless_cookie_cache_fixture(strategy: "compact", refresh_cache: true, max_age: 0, email: "zero-cache-max-age@example.com")

    _, before, cached = stateless_session_response(fixture, 240)
    assert_equal fixture[:original][:session], cached.fetch("session")
    assert_cookie_refresh_headers before, expected: false

    _, after, refreshed = stateless_session_response(fixture, 241)
    assert_equal fixture[:original][:session], refreshed.fetch("session")
    renewal = assert_cookie_refresh_headers after, expected: true
    assert_includes renewal.fetch(:session_data), "Max-Age=300"
  end

  def test_remember_me_false_does_not_refresh_session
    auth = build_auth(session: {update_age: 0, expires_in: 120, cookie_cache: {enabled: false}})
    _signup_cookie = sign_up_cookie(auth, email: "browser-session@example.com")

    status, headers, body = auth.api.sign_in_email(
      body: {email: "browser-session@example.com", password: "password123", rememberMe: false},
      as_response: true
    )
    assert_equal 200, status
    cookie = cookie_header(headers.fetch("set-cookie"))
    token = JSON.parse(body.join).fetch("token")
    original_expiry = auth.context.internal_adapter.find_session(token).fetch(:session).fetch("expiresAt")
    session_cookie_line = headers.fetch("set-cookie").lines.find { |line| line.include?("session_token") }
    refute_includes session_cookie_line, "Max-Age="

    _status, refresh_headers, _refresh_body = auth.api.get_session(headers: {"cookie" => cookie}, as_response: true)

    refute refresh_headers.key?("set-cookie")
    assert_equal original_expiry, auth.context.internal_adapter.find_session(token).fetch(:session).fetch("expiresAt")
  end

  def test_sign_out_deletes_current_session_and_clears_cookies
    deleted = []
    auth = build_auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database_hooks: {
        session: {
          delete: {
            after: ->(session, _context) { deleted << session["token"] }
          }
        }
      }
    )
    cookie = sign_up_cookie(auth, email: "sign-out@example.com")
    session = auth.api.get_session(headers: {"cookie" => cookie})

    status, headers, body = auth.api.sign_out(headers: {"cookie" => cookie}, as_response: true)

    assert_equal 200, status
    assert_equal({"success" => true}, JSON.parse(body.join))
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token="
    assert_includes headers.fetch("set-cookie"), "Max-Age=0"
    assert_includes deleted, session[:session]["token"]
    assert_nil auth.context.internal_adapter.find_session(session[:session]["token"])
    assert_nil auth.api.get_session(headers: {"cookie" => cookie})
  end

  def test_list_sessions_returns_active_sessions_for_current_user
    auth = build_auth
    cookie = sign_up_cookie(auth, email: "list@example.com")
    second_cookie = sign_in_cookie(auth, email: "list@example.com")

    result = auth.api.list_sessions(headers: {"cookie" => second_cookie})

    assert_equal 2, result.length
    assert_equal [auth.api.get_session(headers: {"cookie" => cookie})[:session]["userId"]], result.map { |session| session["userId"] }.uniq
  end

  def test_list_sessions_requires_a_fresh_authoritative_session
    auth = build_auth(session: {fresh_age: 1, expires_in: 3600, update_age: 3600})
    cookie = sign_up_cookie(auth, email: "stale-list@example.com")
    session = auth.api.get_session(headers: {"cookie" => cookie})[:session]
    auth.context.internal_adapter.update_session(session["token"], "createdAt" => Time.now - 120, "updatedAt" => Time.now - 120)

    error = assert_raises(BetterAuth::APIError) { auth.api.list_sessions(headers: {"cookie" => cookie}) }

    assert_equal 403, error.status_code
    assert_equal "SESSION_NOT_FRESH", error.code
  end

  def test_update_session_returns_updated_session_payload
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.additional_fields(
          session: {
            deviceName: {type: "string", required: false}
          }
        )
      ]
    )
    cookie = sign_up_cookie(auth, email: "update-session@example.com")

    result = auth.api.update_session(headers: {"cookie" => cookie}, body: {deviceName: "mobile"})

    assert_equal "mobile", result.fetch(:session).fetch("deviceName")
    refute result.key?(:user)
  end

  def test_update_session_ignores_core_fields_and_updates_cookie
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.additional_fields(
          session: {
            deviceName: {type: "string", required: false}
          }
        )
      ]
    )
    cookie = sign_up_cookie(auth, email: "update-session-core-fields@example.com")
    original = auth.api.get_session(headers: {"cookie" => cookie})

    result = auth.api.update_session(
      headers: {"cookie" => cookie},
      body: {
        token: "attacker-token",
        userId: "attacker-user",
        expiresAt: Time.now + 86_400,
        deviceName: "tablet"
      },
      return_headers: true
    )
    refreshed_cookie = cookie_header(result.fetch(:headers).fetch("set-cookie"))
    refreshed = auth.api.get_session(headers: {"cookie" => refreshed_cookie})

    assert_equal "tablet", result.fetch(:response).fetch(:session).fetch("deviceName")
    assert_equal original[:session]["token"], refreshed[:session]["token"]
    assert_equal original[:session]["userId"], refreshed[:session]["userId"]
    assert_equal "tablet", refreshed[:session]["deviceName"]
  end

  def test_update_session_allows_stale_regular_session
    auth = build_auth(
      session: {fresh_age: 1, expires_in: 3600, update_age: 3600},
      plugins: [
        BetterAuth::Plugins.additional_fields(
          session: {
            deviceName: {type: "string", required: false}
          }
        )
      ]
    )
    cookie = sign_up_cookie(auth, email: "stale-update-session@example.com")
    session = auth.api.get_session(headers: {"cookie" => cookie})[:session]
    auth.context.internal_adapter.update_session(
      session["token"],
      "createdAt" => Time.now - 120,
      "updatedAt" => Time.now - 120
    )

    result = auth.api.update_session(headers: {"cookie" => cookie}, body: {deviceName: "desktop"})

    assert_equal "desktop", result.fetch(:session).fetch("deviceName")
  end

  def test_update_session_fails_closed_when_cached_backing_session_was_deleted
    auth = build_auth(
      session: {cookie_cache: {enabled: true, strategy: "jwe", max_age: 300}},
      plugins: [
        BetterAuth::Plugins.additional_fields(
          session: {deviceName: {type: "string", required: false}}
        )
      ]
    )
    cookie = sign_up_cookie(auth, email: "revoked-update-session@example.com")
    token = auth.api.get_session(headers: {"cookie" => cookie})[:session]["token"]
    auth.context.internal_adapter.delete_session(token)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.update_session(headers: {"cookie" => cookie}, body: {deviceName: "desktop"})
    end

    assert_equal 401, error.status_code
    assert_equal BetterAuth::BASE_ERROR_CODES.fetch("FAILED_TO_GET_SESSION"), error.message
    assert_nil auth.context.internal_adapter.find_session(token)
  end

  def test_session_refresh_fails_closed_when_row_is_deleted_during_update
    adapter = nil
    delete_on_refresh = false
    auth = build_auth(
      session: {update_age: 60, expires_in: 300, cookie_cache: {enabled: false}},
      database_hooks: {
        session: {
          update: {
            before: lambda do |_data, _context|
              adapter.delete(model: "session", where: [{field: "token", value: delete_on_refresh}]) if delete_on_refresh
              nil
            end
          }
        }
      }
    )
    adapter = auth.context.adapter
    cookie = sign_up_cookie(auth, email: "concurrent-refresh@example.com")
    session = auth.api.get_session(headers: {"cookie" => cookie})[:session]
    adapter.update(model: "session", where: [{field: "token", value: session["token"]}], update: {expiresAt: Time.now + 180})
    delete_on_refresh = session["token"]

    status, headers, body = auth.api.get_session(headers: {"cookie" => cookie}, as_response: true)

    assert_equal 401, status
    assert_equal BetterAuth::BASE_ERROR_CODES.fetch("FAILED_TO_GET_SESSION"), JSON.parse(body.join).fetch("message")
    assert headers.fetch("set-cookie").lines.all? { |line| !line.start_with?("better-auth.session_token=") || line.include?("Max-Age=0") }
    assert_nil auth.context.internal_adapter.find_session(session["token"])
  end

  def test_revoke_session_deletes_only_matching_user_session
    auth = build_auth
    first_cookie = sign_up_cookie(auth, email: "revoke@example.com")
    second_cookie = sign_in_cookie(auth, email: "revoke@example.com")
    first_token = auth.api.get_session(headers: {"cookie" => first_cookie})[:session]["token"]

    result = auth.api.revoke_session(headers: {"cookie" => second_cookie}, body: {token: first_token})

    assert_equal({status: true}, result)
    assert_nil auth.api.get_session(headers: {"cookie" => first_cookie})
    refute_nil auth.api.get_session(headers: {"cookie" => second_cookie})
  end

  def test_sensitive_session_routes_ignore_cookie_cache_without_requiring_fresh_session
    auth = build_auth(session: {fresh_age: 60, cookie_cache: {enabled: true, strategy: "jwe", max_age: 300}})
    cookie = sign_up_cookie(auth, email: "stale-sensitive@example.com")
    session = auth.api.get_session(headers: {"cookie" => cookie})
    auth.context.adapter.update(
      model: "session",
      where: [{field: "token", value: session[:session]["token"]}],
      update: {createdAt: Time.now - 300, updatedAt: Time.now - 300}
    )

    assert_equal({status: true}, auth.api.revoke_sessions(headers: {"cookie" => cookie}))
    assert_nil auth.api.get_session(headers: {"cookie" => cookie}, query: {disableCookieCache: true})
  end

  def test_revoke_sessions_deletes_all_current_user_sessions
    auth = build_auth
    first_cookie = sign_up_cookie(auth, email: "revoke-all@example.com")
    second_cookie = sign_in_cookie(auth, email: "revoke-all@example.com")

    result = auth.api.revoke_sessions(headers: {"cookie" => second_cookie})

    assert_equal({status: true}, result)
    assert_nil auth.api.get_session(headers: {"cookie" => first_cookie})
    assert_nil auth.api.get_session(headers: {"cookie" => second_cookie})
  end

  def test_revoke_other_sessions_keeps_current_session
    auth = build_auth
    first_cookie = sign_up_cookie(auth, email: "revoke-other@example.com")
    second_cookie = sign_in_cookie(auth, email: "revoke-other@example.com")

    result = auth.api.revoke_other_sessions(headers: {"cookie" => second_cookie})

    assert_equal({status: true}, result)
    assert_nil auth.api.get_session(headers: {"cookie" => first_cookie})
    refute_nil auth.api.get_session(headers: {"cookie" => second_cookie})
  end

  def test_secondary_storage_stores_lists_and_revokes_session
    storage = StringStorage.new
    auth = build_auth(secondary_storage: storage)
    cookie = sign_up_cookie(auth, email: "secondary-session@example.com")
    session = auth.api.get_session(headers: {"cookie" => cookie})
    user_id = session[:user]["id"]
    token = session[:session]["token"]

    assert_equal ["active-sessions-#{user_id}", token].sort, storage.keys.sort
    stored_session = JSON.parse(storage.get(token))
    assert_equal user_id, stored_session.fetch("user").fetch("id")
    assert_equal user_id, stored_session.fetch("session").fetch("userId")
    assert stored_session.fetch("session").fetch("id")
    active_sessions = JSON.parse(storage.get("active-sessions-#{user_id}"))
    assert_equal [{"token" => token, "expiresAt" => active_sessions.first.fetch("expiresAt")}], active_sessions
    assert_equal [token], auth.api.list_sessions(headers: {"cookie" => cookie}).map { |entry| entry["token"] }

    result = auth.api.revoke_session(headers: {"cookie" => cookie}, body: {token: token})

    assert_equal({status: true}, result)
    assert_empty storage.keys
    assert_nil auth.api.get_session(headers: {"cookie" => cookie})
  end

  def test_secondary_storage_without_database_does_not_use_default_cookie_cache_after_revocation
    storage = StringStorage.new
    auth = build_auth(database: nil, secondary_storage: storage)
    cookie = sign_up_cookie(auth, email: "secondary-stateless-revocation@example.com")
    token = auth.api.get_session(headers: {"cookie" => cookie}).fetch(:session).fetch("token")

    assert_equal({status: true}, auth.api.revoke_session(headers: {"cookie" => cookie}, body: {token: token}))
    assert_nil auth.api.get_session(headers: {"cookie" => cookie})
  end

  def test_secondary_storage_can_return_already_parsed_objects
    storage = ObjectStorage.new
    auth = build_auth(secondary_storage: storage)
    cookie = sign_up_cookie(auth, email: "object-storage@example.com")

    session = auth.api.get_session(headers: {"cookie" => cookie})
    active = storage.get("active-sessions-#{session[:user]["id"]}")

    assert_kind_of Array, active
    assert_equal 1, active.length
    assert_equal 1, auth.api.list_sessions(headers: {"cookie" => cookie}).length

    result = auth.api.revoke_session(headers: {"cookie" => cookie}, body: {token: session[:session]["token"]})

    assert_equal({status: true}, result)
    assert_nil auth.api.get_session(headers: {"cookie" => cookie})
    assert_nil storage.get("active-sessions-#{session[:user]["id"]}")
  end

  def test_revoke_session_deletes_database_copy_when_secondary_storage_database_preserve_is_false
    storage = StringStorage.new
    auth = build_auth(secondary_storage: storage, session: {store_session_in_database: true, preserve_session_in_database: false})
    cookie = sign_up_cookie(auth, email: "secondary-db-delete@example.com")
    token = auth.api.get_session(headers: {"cookie" => cookie})[:session]["token"]

    result = auth.api.revoke_session(headers: {"cookie" => cookie}, body: {token: token})

    assert_equal({status: true}, result)
    assert_nil storage.get(token)
    assert_nil auth.context.adapter.find_one(model: "session", where: [{field: "token", value: token}])
    assert_nil auth.api.get_session(headers: {"cookie" => cookie})
  end

  def test_revoke_session_preserves_database_copy_without_restoring_revoked_secondary_session
    storage = StringStorage.new
    auth = build_auth(secondary_storage: storage, session: {store_session_in_database: true, preserve_session_in_database: true})
    cookie = sign_up_cookie(auth, email: "secondary-db-preserve@example.com")
    token = auth.api.get_session(headers: {"cookie" => cookie})[:session]["token"]

    result = auth.api.revoke_session(headers: {"cookie" => cookie}, body: {token: token})

    assert_equal({status: true}, result)
    assert_nil storage.get(token)
    assert auth.context.adapter.find_one(model: "session", where: [{field: "token", value: token}])
    assert_nil auth.api.get_session(headers: {"cookie" => cookie})
  end

  def test_get_session_returns_nil_and_clears_cookie_when_database_session_is_missing
    auth = build_auth(session: {cookie_cache: {enabled: false}})
    cookie = sign_up_cookie(auth, email: "missing-db@example.com")
    session = auth.api.get_session(headers: {"cookie" => cookie})
    auth.context.internal_adapter.delete_session(session[:session]["token"])

    status, headers, body = auth.api.get_session(headers: {"cookie" => cookie}, as_response: true)

    assert_equal 200, status
    assert_nil JSON.parse(body.join)
    assert_includes headers.fetch("set-cookie"), "Max-Age=0"
  end

  def test_get_session_returns_nil_and_clears_cookie_for_tampered_signed_session_token
    auth = build_auth(session: {cookie_cache: {enabled: false}})
    cookie = sign_up_cookie(auth, email: "tampered-token@example.com")
    tampered = cookie.sub(/(better-auth\.session_token=)([^;]+)/) { "#{$1}#{$2}tampered" }

    status, headers, body = auth.api.get_session(headers: {"cookie" => tampered}, as_response: true)

    assert_equal 200, status
    assert_nil JSON.parse(body.join)
    assert_includes headers.fetch("set-cookie"), "Max-Age=0"
  end

  def test_get_session_uses_cookie_cache_for_compact_jwt_and_jwe_strategies
    %w[compact jwt jwe].each do |strategy|
      auth = build_auth(session: {cookie_cache: {enabled: true, strategy: strategy, max_age: 300}})
      cookie = sign_up_cookie(auth, email: "#{strategy}-cache@example.com")
      session = auth.api.get_session(headers: {"cookie" => cookie})
      auth.context.adapter.update(
        model: "user",
        where: [{field: "id", value: session[:user]["id"]}],
        update: {name: "Database #{strategy}"}
      )

      cached = auth.api.get_session(headers: {"cookie" => cookie})
      authoritative = auth.api.get_session(headers: {"cookie" => cookie}, query: {disableCookieCache: true})

      refute_equal "Database #{strategy}", cached[:user]["name"]
      assert_equal "Database #{strategy}", authoritative[:user]["name"]
    end
  end

  def test_get_session_date_fields_are_parseable_strings
    auth = build_auth(session: {cookie_cache: {enabled: true, strategy: "jwe", max_age: 300}})
    cookie = sign_up_cookie(auth, email: "date-fields@example.com")
    result = auth.api.get_session(headers: {"cookie" => cookie})

    %w[createdAt updatedAt expiresAt].each do |field|
      assert_kind_of String, result[:session][field]
      assert Time.parse(result[:session][field])
    end
  end

  def test_update_session_rejects_undeclared_fields_without_updating_session
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.additional_fields(
          session: {
            deviceName: {type: "string", required: false}
          }
        )
      ]
    )
    cookie = sign_up_cookie(auth, email: "undeclared-session-field@example.com")
    original = auth.api.get_session(headers: {"cookie" => cookie})

    error = assert_raises(BetterAuth::APIError) do
      auth.api.update_session(headers: {"cookie" => cookie}, body: {unknownField: "ignored"})
    end

    assert_equal 400, error.status_code
    assert_equal "No fields to update", error.message
    refreshed = auth.api.get_session(headers: {"cookie" => cookie})
    assert_equal original[:session], refreshed[:session]
  end

  private

  def build_auth(options = {})
    email_and_password = {enabled: true}.merge(options.fetch(:email_and_password, {}))
    BetterAuth.auth({base_url: "http://localhost:3000", secret: SECRET, database: :memory}.merge(options).merge(email_and_password: email_and_password))
  end

  def sign_up_cookie(auth, email:)
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: email, password: "password123", name: "Session User"},
      as_response: true
    )
    cookie_header(headers.fetch("set-cookie"))
  end

  def sign_in_cookie(auth, email:, remember_me: nil)
    body = {email: email, password: "password123"}
    body[:rememberMe] = remember_me unless remember_me.nil?
    _status, headers, _body = auth.api.sign_in_email(
      body: body,
      as_response: true
    )
    cookie_header(headers.fetch("set-cookie"))
  end

  def cookie_header(set_cookie)
    set_cookie.lines.map { |line| line.split(";").first }.join("; ")
  end

  def stateless_cookie_cache_fixture(strategy:, refresh_cache:, email:, max_age: 300, expires_in: 3600, remember_me: true)
    issued_at = Time.utc(2026, 7, 12, 12, 0, 0)
    cookie_cache = {enabled: true, strategy: strategy, refresh_cache: refresh_cache}
    cookie_cache[:max_age] = max_age if max_age
    auth = build_auth(
      database: nil,
      session: {update_age: 30, expires_in: expires_in, cookie_cache: cookie_cache}
    )
    cookie = Time.stub(:now, issued_at) do
      sign_up = sign_up_cookie(auth, email: email)
      next sign_in_cookie(auth, email: email, remember_me: false) unless remember_me

      sign_up
    end
    original = Time.stub(:now, issued_at) { auth.api.get_session(headers: {"cookie" => cookie}) }
    auth.context.internal_adapter.delete_session(original[:session]["token"])

    {auth: auth, cookie: cookie, issued_at: issued_at, original: original}
  end

  def stateless_session_response(fixture, elapsed_seconds)
    status, headers, body = Time.stub(:now, fixture[:issued_at] + elapsed_seconds) do
      fixture[:auth].api.get_session(headers: {"cookie" => fixture[:cookie]}, as_response: true)
    end

    [status, headers, JSON.parse(body.join)]
  end

  def assert_cookie_refresh_headers(headers, expected:, message: nil)
    lines = headers.fetch("set-cookie", "").to_s.lines(chomp: true)
    refresh_headers = {}
    {session_data: "better-auth.session_data", session_token: "better-auth.session_token"}.each do |key, name|
      matching = lines.select { |line| line.start_with?("#{name}=") }

      unless expected
        assert_empty matching, message
        next
      end

      nonempty = matching.find do |line|
        !line.start_with?("#{name}=;") && !line.include?("Max-Age=0")
      end
      refute_nil nonempty, message
      refresh_headers[key] = nonempty
    end

    refresh_headers
  end

  class ObjectStorage
    def initialize
      @store = {}
    end

    def set(key, value, _ttl = nil)
      @store[key] = JSON.parse(value)
    end

    def get(key)
      @store[key]
    end

    def delete(key)
      @store.delete(key)
    end
  end

  class StringStorage
    def initialize
      @store = {}
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

    def keys
      @store.keys
    end
  end
end
