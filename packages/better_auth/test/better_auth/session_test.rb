# frozen_string_literal: true

require "test_helper"

class BetterAuthSessionTest < Minitest::Test
  SECRET = "phase-four-secret-with-enough-entropy-456"

  def test_find_current_session_from_signed_cookie
    auth = BetterAuth.auth(secret: SECRET, session: {cookie_cache: {enabled: false}})
    user = auth.context.internal_adapter.create_user("name" => "Ada", "email" => "ada@example.com")
    session = auth.context.internal_adapter.create_session(user["id"], false, {"ipAddress" => "127.0.0.1", "userAgent" => "Minitest"})
    ctx = endpoint_context(auth)
    BetterAuth::Cookies.set_session_cookie(ctx, {session: session, user: user}, false)
    request_ctx = endpoint_context(auth, cookie: ctx.response_headers.fetch("set-cookie").lines.first.split(";").first)

    result = BetterAuth::Session.find_current(request_ctx)

    assert_equal session["token"], result[:session]["token"]
    assert_equal user["id"], result[:user]["id"]
  end

  def test_find_current_session_refreshes_expiration_when_update_age_is_reached
    auth = BetterAuth.auth(secret: SECRET, session: {update_age: 0, expires_in: 120, cookie_cache: {enabled: false}})
    user = auth.context.internal_adapter.create_user("name" => "Ada", "email" => "ada@example.com")
    session = auth.context.internal_adapter.create_session(user["id"])
    old_expiration = session["expiresAt"]
    ctx = endpoint_context(auth)
    BetterAuth::Cookies.set_session_cookie(ctx, {session: session, user: user}, false)
    request_ctx = endpoint_context(auth, cookie: ctx.response_headers.fetch("set-cookie").lines.first.split(";").first)

    result = BetterAuth::Session.find_current(request_ctx)

    assert_operator result[:session]["expiresAt"], :>, old_expiration
    assert_includes request_ctx.response_headers.fetch("set-cookie"), "Max-Age=120"
  end

  def test_fresh_current_session_rejects_stale_session
    auth = BetterAuth.auth(secret: SECRET, session: {fresh_age: 60, cookie_cache: {enabled: false}})
    user = auth.context.internal_adapter.create_user("name" => "Ada", "email" => "ada@example.com")
    session = auth.context.internal_adapter.create_session(user["id"])
    auth.context.adapter.update(
      model: "session",
      where: [{field: "token", value: session.fetch("token")}],
      update: {createdAt: Time.now - 120}
    )
    ctx = endpoint_context(auth)
    BetterAuth::Cookies.set_session_cookie(ctx, {session: session, user: user}, false)
    request_ctx = endpoint_context(auth, cookie: ctx.response_headers.fetch("set-cookie").lines.first.split(";").first)

    error = assert_raises(BetterAuth::APIError) do
      BetterAuth::Routes.current_session(request_ctx, sensitive: true, fresh: true)
    end

    assert_equal 403, error.status_code
    assert_equal BetterAuth::BASE_ERROR_CODES.fetch("SESSION_NOT_FRESH"), error.message
  end

  def test_sensitive_current_session_does_not_require_fresh_session
    auth = BetterAuth.auth(secret: SECRET, session: {fresh_age: 60, cookie_cache: {enabled: false}})
    user = auth.context.internal_adapter.create_user("name" => "Ada", "email" => "ada-sensitive@example.com")
    session = auth.context.internal_adapter.create_session(user["id"])
    auth.context.adapter.update(
      model: "session",
      where: [{field: "token", value: session.fetch("token")}],
      update: {createdAt: Time.now - 120}
    )
    ctx = endpoint_context(auth)
    BetterAuth::Cookies.set_session_cookie(ctx, {session: session, user: user}, false)
    request_ctx = endpoint_context(auth, cookie: ctx.response_headers.fetch("set-cookie").lines.first.split(";").first)

    current_session = BetterAuth::Routes.current_session(request_ctx, sensitive: true)

    assert_equal session.fetch("token"), current_session.fetch(:session).fetch("token")
  end

  def test_sensitive_current_session_allows_stale_session_when_fresh_age_disabled
    auth = BetterAuth.auth(secret: SECRET, session: {fresh_age: 0, cookie_cache: {enabled: false}})
    user = auth.context.internal_adapter.create_user("name" => "Ada", "email" => "ada-disabled@example.com")
    session = auth.context.internal_adapter.create_session(user["id"])
    auth.context.adapter.update(
      model: "session",
      where: [{field: "token", value: session.fetch("token")}],
      update: {createdAt: Time.now - 120}
    )
    ctx = endpoint_context(auth)
    BetterAuth::Cookies.set_session_cookie(ctx, {session: session, user: user}, false)
    request_ctx = endpoint_context(auth, cookie: ctx.response_headers.fetch("set-cookie").lines.first.split(";").first)

    current_session = BetterAuth::Routes.current_session(request_ctx, sensitive: true)

    assert_equal session.fetch("token"), current_session.fetch(:session).fetch("token")
  end

  def test_sensitive_current_session_bypasses_memoized_stateful_session
    auth = BetterAuth.auth(secret: SECRET, database: :memory, session: {cookie_cache: {enabled: true, strategy: "jwe", max_age: 300}})
    user = auth.context.internal_adapter.create_user("name" => "Ada", "email" => "ada-revoked@example.com")
    session = auth.context.internal_adapter.create_session(user["id"])
    cookie_ctx = endpoint_context(auth)
    BetterAuth::Cookies.set_session_cookie(cookie_ctx, {session: session, user: user}, false)
    cookie = cookie_ctx.response_headers.fetch("set-cookie").lines.map { |line| line.split(";").first }.join("; ")
    request_ctx = endpoint_context(auth, cookie: cookie)

    assert_equal session["token"], BetterAuth::Routes.current_session(request_ctx)[:session]["token"]
    auth.context.internal_adapter.delete_session(session["token"])

    error = assert_raises(BetterAuth::APIError) do
      BetterAuth::Routes.current_session(request_ctx, sensitive: true)
    end
    assert_equal 401, error.status_code
    assert_nil auth.context.current_session
    assert_includes request_ctx.response_headers.fetch("set-cookie"), "Max-Age=0"
  end

  def test_find_current_session_expires_cookie_when_session_is_missing
    auth = BetterAuth.auth(secret: SECRET, session: {cookie_cache: {enabled: false}})
    ctx = endpoint_context(auth)
    ctx.set_signed_cookie(auth.context.auth_cookies[:session_token].name, "missing-token", SECRET)
    request_ctx = endpoint_context(auth, cookie: ctx.response_headers.fetch("set-cookie").split(";").first)

    assert_nil BetterAuth::Session.find_current(request_ctx)
    assert_includes request_ctx.response_headers.fetch("set-cookie"), "Max-Age=0"
  end

  def test_find_current_session_expires_cookie_when_database_session_is_expired
    auth = BetterAuth.auth(secret: SECRET, session: {cookie_cache: {enabled: false}})
    user = auth.context.internal_adapter.create_user("name" => "Ada", "email" => "expired@example.com")
    session = auth.context.internal_adapter.create_session(user["id"], false, {"ipAddress" => "127.0.0.1", "userAgent" => "Minitest"})
    auth.context.adapter.update(
      model: "session",
      where: [{field: "token", value: session.fetch("token")}],
      update: {expiresAt: Time.now - 1}
    )
    ctx = endpoint_context(auth)
    BetterAuth::Cookies.set_session_cookie(ctx, {session: session, user: user}, false)
    request_ctx = endpoint_context(auth, cookie: ctx.response_headers.fetch("set-cookie").lines.first.split(";").first)

    assert_nil BetterAuth::Session.find_current(request_ctx)
    assert_includes request_ctx.response_headers.fetch("set-cookie"), "Max-Age=0"
  end

  def test_find_current_session_rejects_tampered_signed_session_cookie
    auth = BetterAuth.auth(secret: SECRET, session: {cookie_cache: {enabled: false}})
    user = auth.context.internal_adapter.create_user("name" => "Ada", "email" => "tampered@example.com")
    session = auth.context.internal_adapter.create_session(user["id"])
    ctx = endpoint_context(auth)
    BetterAuth::Cookies.set_session_cookie(ctx, {session: session, user: user}, false)
    cookie = ctx.response_headers.fetch("set-cookie").lines.first.split(";").first
    tampered = cookie.sub(/(better-auth\.session_token=)([^;]+)/) { "#{$1}#{$2}tampered" }
    request_ctx = endpoint_context(auth, cookie: tampered)

    assert_nil BetterAuth::Session.find_current(request_ctx)
    assert_includes request_ctx.response_headers.fetch("set-cookie"), "Max-Age=0"
  end

  private

  def endpoint_context(auth, cookie: nil)
    headers = {}
    headers["cookie"] = cookie if cookie
    BetterAuth::Endpoint::Context.new(
      path: "/test",
      method: "GET",
      query: {},
      body: {},
      params: {},
      headers: headers,
      context: auth.context
    )
  end
end
