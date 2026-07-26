# frozen_string_literal: true

require "json"
require "rack/mock"
require_relative "../../test_helper"

class BetterAuthPluginsExpoTest < Minitest::Test
  SECRET = "phase-twelve-secret-with-enough-entropy-123"

  def test_authorization_proxy_sets_signed_state_cookie_and_redirects
    auth = build_auth
    authorization_url = "https://provider.example.com/auth?state=oauth-state"
    status, headers, _body = auth.api.expo_authorization_proxy(
      query: {authorizationURL: authorization_url},
      as_response: true
    )

    assert_equal 302, status
    assert_equal authorization_url, headers.fetch("location")
    assert_includes headers.fetch("set-cookie"), "better-auth.state="

    status, headers, _body = auth.api.expo_authorization_proxy(
      query: {authorizationURL: authorization_url, oauthState: "cookie-state"},
      as_response: true
    )

    assert_equal 302, status
    assert_includes headers.fetch("set-cookie"), "better-auth.oauth_state=cookie-state"
  end

  def test_authorization_proxy_rejects_invalid_targets_before_setting_state_cookie
    auth = build_auth(base_url: "https://app.example")
    invalid_targets = {
      "same origin with oauth state" => ["https://app.example/api/auth/callback/google?state=x", "attacker-state"],
      "same normalized origin" => ["https://user:password@APP.EXAMPLE:443/api/auth/callback/google?state=x", nil],
      "external http" => ["http://accounts.google.com/o/oauth2/v2/auth?state=x", nil],
      "non-url" => ["not-a-url", nil],
      "malformed" => ["https://accounts.google.com/%?state=x", nil],
      "relative" => ["/oauth2/authorize?state=x", nil],
      "protocol relative" => ["//accounts.google.com/o/oauth2/v2/auth?state=x", nil],
      "fragment" => ["https://accounts.google.com/o/oauth2/v2/auth?state=x#fragment", nil],
      "bare fragment" => ["https://accounts.google.com/o/oauth2/v2/auth?state=x#", nil]
    }

    invalid_targets.each do |label, (authorization_url, oauth_state)|
      params = {"authorizationURL" => authorization_url}
      params["oauthState"] = oauth_state if oauth_state
      response = Rack::MockRequest.new(auth.handler).get("/api/auth/expo-authorization-proxy", params: params)

      assert_equal 400, response.status, label
      assert_equal "Invalid authorizationURL", JSON.parse(response.body).fetch("message"), label
      assert_nil response["location"], label
      assert_nil response["set-cookie"], label
    end
  end

  def test_authorization_proxy_redirects_external_https_targets_unchanged
    auth = build_auth(base_url: "https://app.example")
    authorization_urls = [
      "https://accounts.google.com/o/oauth2/v2/auth?client_id=x&state=abc",
      "https://app.example:444/oauth2/authorize?state=non-default-port"
    ]

    authorization_urls.each do |authorization_url|
      response = Rack::MockRequest.new(auth.handler).get(
        "/api/auth/expo-authorization-proxy",
        params: {"authorizationURL" => authorization_url}
      )

      assert_equal 302, response.status
      assert_equal authorization_url, response["location"]
      assert_includes response["set-cookie"], "better-auth.state="
    end
  end

  def test_expo_origin_header_is_used_when_origin_is_missing
    auth = build_auth
    app = auth.handler
    env = Rack::MockRequest.env_for(
      "http://localhost:3000/api/auth/sign-up/email",
      :method => "POST",
      "CONTENT_TYPE" => "application/json",
      "HTTP_EXPO_ORIGIN" => "http://localhost:3000",
      :input => JSON.generate({email: "expo@example.com", password: "password123", name: "Expo"})
    )

    status, = app.call(env)

    assert_equal 200, status
  end

  def test_deep_link_redirect_receives_cookie_query_param_for_trusted_origin
    auth = build_auth(trusted_origins: ["myapp://"])

    status, headers, _body = auth.api.verify_email(
      query: {token: "missing", callbackURL: "myapp://verified"},
      as_response: true
    )

    assert_equal 302, status
    location = headers.fetch("location")
    assert_match(/\Amyapp:\/\/verified/, location)
    refute_includes location, "cookie="

    ctx = BetterAuth::Endpoint::Context.new(
      path: "/verify-email",
      method: "GET",
      query: {},
      body: {},
      params: {},
      headers: {},
      context: auth.context
    )
    ctx.set_header("location", "myapp://verified")
    ctx.set_header("set-cookie", "better-auth.session_token=abc; Path=/; HttpOnly")
    hook = auth.context.options.plugins.first.hooks.fetch(:after).first
    hook.fetch(:handler).call(ctx)

    assert_includes ctx.response_headers.fetch("location"), "cookie=better-auth.session_token%3Dabc"
  end

  def test_disable_origin_override_preserves_core_missing_origin_behavior
    auth = build_auth(disable_origin_override: true)
    app = auth.handler
    env = Rack::MockRequest.env_for(
      "http://localhost:3000/api/auth/sign-up/email",
      :method => "POST",
      "CONTENT_TYPE" => "application/json",
      "HTTP_EXPO_ORIGIN" => "http://localhost:3000",
      :input => JSON.generate({email: "blocked-expo@example.com", password: "password123", name: "Expo"})
    )

    status, = app.call(env)

    assert_equal 200, status
  end

  def test_origin_header_is_not_replaced_when_already_present
    observed_origin = nil
    observer = BetterAuth::Plugin.new(
      id: "observer",
      hooks: {
        before: [
          {
            matcher: ->(_ctx) { true },
            handler: ->(ctx) {
              observed_origin = ctx.headers["origin"]
              nil
            }
          }
        ]
      }
    )
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: :memory,
      email_and_password: {enabled: true},
      trusted_origins: ["http://client.example"],
      plugins: [BetterAuth::Plugins.expo, observer]
    )
    app = auth.handler
    env = Rack::MockRequest.env_for(
      "http://localhost:3000/api/auth/sign-up/email",
      :method => "POST",
      "CONTENT_TYPE" => "application/json",
      "HTTP_ORIGIN" => "http://client.example",
      "HTTP_EXPO_ORIGIN" => "better-auth://",
      :input => JSON.generate({email: "origin-present@example.com", password: "password123", name: "Expo"})
    )

    status, = app.call(env)

    assert_equal 200, status
    assert_equal "http://client.example", observed_origin
  end

  def test_authorization_proxy_rejects_missing_authorization_url
    auth = build_auth

    assert_raises(BetterAuth::APIError) do
      auth.api.expo_authorization_proxy(query: {})
    end

    assert_raises(BetterAuth::APIError) do
      auth.api.expo_authorization_proxy(query: {oauthState: "state"})
    end
  end

  def test_deep_link_redirect_receives_cookie_for_wildcard_trusted_origin
    auth = build_auth(trusted_origins: ["myapp://*"])
    ctx = BetterAuth::Endpoint::Context.new(
      path: "/magic-link/verify",
      method: "GET",
      query: {},
      body: {},
      params: {},
      headers: {},
      context: auth.context
    )
    ctx.set_header("location", "myapp:///dashboard")
    ctx.set_header("set-cookie", "better-auth.session_token=abc; Path=/; HttpOnly")
    hook = auth.context.options.plugins.first.hooks.fetch(:after).first
    hook.fetch(:handler).call(ctx)

    assert_includes ctx.response_headers.fetch("location"), "cookie=better-auth.session_token%3Dabc"
  end

  def test_deep_link_redirect_receives_full_set_cookie_header
    auth = build_auth(trusted_origins: ["myapp://"])
    ctx = BetterAuth::Endpoint::Context.new(
      path: "/verify-email",
      method: "GET",
      query: {},
      body: {},
      params: {},
      headers: {},
      context: auth.context
    )
    full_cookie = "better-auth.session_token=abc; Path=/; HttpOnly, better-auth.session_data=xyz; Path=/; Max-Age=300"
    ctx.set_header("location", "myapp://verified")
    ctx.set_header("set-cookie", full_cookie)
    hook = auth.context.options.plugins.first.hooks.fetch(:after).first

    hook.fetch(:handler).call(ctx)

    location = URI.parse(ctx.response_headers.fetch("location"))
    assert_equal full_cookie, Rack::Utils.parse_query(location.query).fetch("cookie")
  end

  def test_exp_scheme_is_only_trusted_in_development
    with_env("RACK_ENV" => "production", "RAILS_ENV" => nil, "APP_ENV" => nil) do
      auth = build_auth
      refute_includes auth.context.trusted_origins, "exp://"
    end

    with_env("RACK_ENV" => "development", "RAILS_ENV" => nil, "APP_ENV" => nil) do
      auth = build_auth
      assert_includes auth.context.trusted_origins, "exp://"
    end
  end

  private

  def build_auth(plugin_options = {})
    base_url = plugin_options.delete(:base_url) || "http://localhost:3000"
    trusted_origins = plugin_options.delete(:trusted_origins)
    auth_options = {
      base_url: base_url,
      secret: SECRET,
      database: :memory,
      email_and_password: {enabled: true},
      plugins: [BetterAuth::Plugins.expo(plugin_options)]
    }
    auth_options[:trusted_origins] = trusted_origins if trusted_origins
    BetterAuth.auth(auth_options)
  end

  def with_env(values)
    previous = values.each_with_object({}) { |(key, _value), memo| memo[key] = ENV[key] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
