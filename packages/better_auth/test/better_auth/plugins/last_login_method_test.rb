# frozen_string_literal: true

require_relative "../../test_helper"
require "rack/mock"

class BetterAuthPluginsLastLoginMethodTest < Minitest::Test
  SECRET = "phase-seven-secret-with-enough-entropy-123"

  def test_last_login_method_sets_cookie_on_successful_email_sign_in
    auth = build_auth(plugins: [BetterAuth::Plugins.last_login_method])
    auth.api.sign_up_email(body: {email: "last@example.com", password: "password123", name: "Last"})

    _status, headers, _body = auth.api.sign_in_email(
      body: {email: "last@example.com", password: "password123"},
      as_response: true
    )

    assert_includes headers.fetch("set-cookie"), "better-auth.last_used_login_method=email"
  end

  def test_last_login_method_sets_cookie_on_successful_email_sign_up
    auth = build_auth(plugins: [BetterAuth::Plugins.last_login_method])

    _status, headers, _body = auth.api.sign_up_email(
      body: {email: "last-signup@example.com", password: "password123", name: "Last Signup"},
      as_response: true
    )

    assert_includes headers.fetch("set-cookie"), "better-auth.last_used_login_method=email"
  end

  def test_last_login_method_does_not_set_cookie_on_failed_sign_in
    auth = build_auth(plugins: [BetterAuth::Plugins.last_login_method])
    auth.api.sign_up_email(body: {email: "last-fail@example.com", password: "password123", name: "Last"})

    status, headers, _body = auth.api.sign_in_email(
      body: {email: "last-fail@example.com", password: "wrong-password"},
      as_response: true
    )

    assert_equal 401, status
    refute_includes headers.fetch("set-cookie", ""), "better-auth.last_used_login_method"
  end

  def test_last_login_method_can_store_in_database
    auth = build_auth(plugins: [BetterAuth::Plugins.last_login_method(store_in_database: true)])
    auth.api.sign_up_email(body: {email: "last-db@example.com", password: "password123", name: "Last DB"})

    _status, headers, _body = auth.api.sign_in_email(
      body: {email: "last-db@example.com", password: "password123"},
      as_response: true
    )
    cookie = headers.fetch("set-cookie").lines.map { |line| line.split(";").first }.join("; ")
    session = auth.api.get_session(headers: {"cookie" => cookie}, query: {disableCookieCache: true})

    assert_equal "email", session[:user]["lastLoginMethod"]
  end

  def test_last_login_method_sets_magic_link_cookie_and_database_value
    sent = []
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.last_login_method(store_in_database: true),
        BetterAuth::Plugins.magic_link(send_magic_link: ->(data, _ctx = nil) { sent << data })
      ]
    )

    auth.api.sign_in_magic_link(body: {email: "magic-last@example.com", callbackURL: "/dashboard"})
    _status, headers, _body = auth.api.magic_link_verify(
      query: {token: sent.first.fetch(:token), callbackURL: "/dashboard"},
      as_response: true
    )
    cookie = cookie_header(headers.fetch("set-cookie"))
    session = auth.api.get_session(headers: {"cookie" => cookie}, query: {disableCookieCache: true})

    assert_includes headers.fetch("set-cookie"), "better-auth.last_used_login_method=magic-link"
    assert_equal "magic-link", session[:user]["lastLoginMethod"]
  end

  def test_last_login_method_schema_uses_upstream_default_field_name
    plugin = BetterAuth::Plugins.last_login_method(store_in_database: true)
    fields = plugin.schema.fetch(:user).fetch(:fields)
    last_login_method = fields[:lastLoginMethod] || fields["lastLoginMethod"] || fields[:last_login_method] || fields["last_login_method"]

    assert_equal "lastLoginMethod", last_login_method.fetch(:field_name)
  end

  def test_last_login_method_custom_resolver_tolerates_missing_path
    calls = []
    plugin = BetterAuth::Plugins.last_login_method(
      custom_resolve_method: ->(ctx) {
        calls << ctx.path
        ctx.path.start_with?("/custom-login") ? "custom" : nil
      }
    )
    auth = build_auth(
      plugins: [plugin]
    )
    ctx = BetterAuth::Endpoint::Context.new(
      path: nil,
      method: "GET",
      query: {},
      body: {},
      params: {},
      headers: {},
      context: auth.context
    )

    assert_nil BetterAuth::Plugins.resolve_login_method(ctx, plugin.options)
    assert_equal [""], calls
  end

  def test_last_login_method_sets_cookie_and_database_value_for_siwe
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.last_login_method(store_in_database: true),
        BetterAuth::Plugins.siwe(
          domain: "example.com",
          get_nonce: -> { "A1b2C3d4E5f6G7h8J" },
          verify_message: ->(message:, signature:, **) { message == "valid_message" && signature == "valid_signature" }
        )
      ]
    )
    wallet = "0x000000000000000000000000000000000000dEaD"
    auth.api.get_siwe_nonce(body: {walletAddress: wallet, chainId: 1})

    _status, headers, _body = auth.api.verify_siwe_message(
      body: {message: "valid_message", signature: "valid_signature", walletAddress: wallet, chainId: 1, email: "siwe@example.com"},
      as_response: true
    )
    cookie = headers.fetch("set-cookie").lines.map { |line| line.split(";").first }.join("; ")
    session = auth.api.get_session(headers: {"cookie" => cookie}, query: {disableCookieCache: true})

    assert_includes headers.fetch("set-cookie"), "better-auth.last_used_login_method=siwe"
    assert_equal "siwe", session[:user]["lastLoginMethod"]
  end

  def test_last_login_method_updates_database_on_social_and_generic_oauth_callbacks
    social = build_auth(
      plugins: [BetterAuth::Plugins.last_login_method(store_in_database: true)],
      social_providers: {
        google: {
          create_authorization_url: ->(data) { "https://accounts.google.com/o/oauth2/v2/auth?state=#{Rack::Utils.escape(data[:state])}" },
          validate_authorization_code: ->(_data) { {accessToken: "access-token"} },
          get_user_info: ->(_tokens) { {user: {id: "google-sub", email: "oauth@example.com", name: "OAuth User", emailVerified: true}} }
        }
      }
    )
    social_sign_in = social.api.sign_in_social(body: {provider: "google", callbackURL: "/dashboard"})
    social_state = Rack::Utils.parse_query(URI.parse(social_sign_in[:url]).query).fetch("state")
    _social_status, social_headers, = social.api.callback_oauth(
      params: {providerId: "google"},
      query: {code: "code", state: social_state},
      as_response: true
    )
    social_cookie = cookie_header(social_headers.fetch("set-cookie"))
    social_session = social.api.get_session(headers: {"cookie" => social_cookie}, query: {disableCookieCache: true})

    assert_equal "google", social_session[:user]["lastLoginMethod"]

    generic = build_auth(
      plugins: [
        BetterAuth::Plugins.last_login_method(store_in_database: true),
        BetterAuth::Plugins.generic_oauth(
          config: [
            {
              providerId: "my-provider",
              clientId: "client-id",
              clientSecret: "client-secret",
              authorizationUrl: "https://provider.example.com/authorize",
              tokenUrl: "https://provider.example.com/token",
              getToken: ->(**) { {accessToken: "access-token"} },
              getUserInfo: ->(_tokens) { {id: "generic-sub", email: "generic@example.com", name: "Generic User", emailVerified: true} }
            }
          ]
        )
      ]
    )
    generic_sign_in = generic.api.sign_in_with_oauth2(body: {providerId: "my-provider", callbackURL: "/dashboard"})
    generic_state = Rack::Utils.parse_query(URI.parse(generic_sign_in[:url]).query).fetch("state")
    _generic_status, generic_headers, = generic.api.oauth2_callback(
      params: {providerId: "my-provider"},
      query: {code: "code", state: generic_state},
      as_response: true
    )
    generic_cookie = cookie_header(generic_headers.fetch("set-cookie"))
    generic_session = generic.api.get_session(headers: {"cookie" => generic_cookie}, query: {disableCookieCache: true})

    assert_equal "my-provider", generic_session[:user]["lastLoginMethod"]
  end

  def test_last_login_method_does_not_set_cookie_on_failed_oauth_callback
    auth = build_auth(
      plugins: [BetterAuth::Plugins.last_login_method],
      social_providers: {
        google: {
          create_authorization_url: ->(data) { "https://accounts.google.com/o/oauth2/v2/auth?state=#{Rack::Utils.escape(data[:state])}" },
          validate_authorization_code: ->(_data) {},
          get_user_info: ->(_tokens) {}
        }
      }
    )
    sign_in = auth.api.sign_in_social(body: {provider: "google", callbackURL: "/dashboard", errorCallbackURL: "/error"})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")

    status, headers, _body = auth.api.callback_oauth(
      params: {providerId: "google"},
      query: {code: "bad-code", state: state},
      as_response: true
    )

    assert_equal 302, status
    refute_includes headers.fetch("set-cookie", ""), "better-auth.last_used_login_method"
  end

  def test_last_login_method_uses_exact_cookie_name_with_custom_prefix_and_advanced_cookie_attributes
    prefixed = build_auth(
      advanced: {cookie_prefix: "custom-auth"},
      plugins: [BetterAuth::Plugins.last_login_method(cookie_name: "my-app.last_method")]
    )
    prefixed.api.sign_up_email(body: {email: "last-prefix@example.com", password: "password123", name: "Last Prefix"})
    _status, headers, _body = prefixed.api.sign_in_email(
      body: {email: "last-prefix@example.com", password: "password123"},
      as_response: true
    )

    assert_includes headers.fetch("set-cookie"), "my-app.last_method=email"
    refute_includes headers.fetch("set-cookie"), "custom-auth.last_method=email"

    cross_subdomain = build_auth(
      base_url: "https://auth.example.com",
      advanced: {cross_subdomain_cookies: {enabled: true, domain: "example.com"}},
      plugins: [BetterAuth::Plugins.last_login_method]
    )
    cross_subdomain.api.sign_up_email(body: {email: "last-domain@example.com", password: "password123", name: "Last Domain"})
    _status, domain_headers, = cross_subdomain.api.sign_in_email(
      body: {email: "last-domain@example.com", password: "password123"},
      as_response: true
    )

    assert_includes domain_headers.fetch("set-cookie"), "better-auth.last_used_login_method=email"
    assert_includes domain_headers.fetch("set-cookie"), "Domain=example.com"
    assert_includes domain_headers.fetch("set-cookie"), "SameSite=Lax"

    cross_origin = build_auth(
      base_url: "https://api.example.com",
      advanced: {default_cookie_attributes: {same_site: "none", secure: true}},
      plugins: [BetterAuth::Plugins.last_login_method]
    )
    cross_origin.api.sign_up_email(body: {email: "last-cross@example.com", password: "password123", name: "Last Cross"})
    _status, cross_headers, = cross_origin.api.sign_in_email(
      body: {email: "last-cross@example.com", password: "password123"},
      as_response: true
    )

    assert_includes cross_headers.fetch("set-cookie"), "better-auth.last_used_login_method=email"
    assert_includes cross_headers.fetch("set-cookie"), "SameSite=None"
    assert_includes cross_headers.fetch("set-cookie"), "Secure"
    refute_includes cross_headers.fetch("set-cookie"), "Domain="
  end

  private

  def build_auth(options = {})
    email_and_password = {enabled: true}.merge(options.fetch(:email_and_password, {}))
    BetterAuth.auth({base_url: "http://localhost:3000", secret: SECRET, database: :memory}.merge(options).merge(email_and_password: email_and_password))
  end

  def cookie_header(set_cookie)
    set_cookie.lines.map { |line| line.split(";").first }.join("; ")
  end
end
