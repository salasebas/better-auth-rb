# frozen_string_literal: true

require "json"
require "rack/mock"
require "stringio"
require_relative "../../test_helper"

class BetterAuthPluginsOAuthProxyTest < Minitest::Test
  SECRET = "phase-eight-secret-with-enough-entropy-123"

  def test_oauth_proxy_callback_requires_profile
    auth = build_auth(plugins: [BetterAuth::Plugins.oauth_proxy])

    status, headers, = auth.api.oauth_proxy(query: {callbackURL: "/dashboard"}, as_response: true)

    assert_equal 302, status
    assert_equal "missing_profile", Rack::Utils.parse_query(URI.parse(headers.fetch("location")).query).fetch("error")
  end

  def test_oauth_proxy_callback_rejects_invalid_encrypted_profiles
    auth = build_auth(plugins: [BetterAuth::Plugins.oauth_proxy])

    invalid_status, invalid_headers, = auth.api.oauth_proxy(query: {callbackURL: "/dashboard", profile: "invalid"}, as_response: true)
    invalid_payload = BetterAuth::Crypto.symmetric_encrypt(key: auth.context.secret, data: JSON.generate({}))
    payload_status, payload_headers, = auth.api.oauth_proxy(query: {callbackURL: "/dashboard", profile: invalid_payload}, as_response: true)

    assert_equal 302, invalid_status
    assert_equal "invalid_profile", Rack::Utils.parse_query(URI.parse(invalid_headers.fetch("location")).query).fetch("error")
    assert_equal 302, payload_status
    assert_equal "invalid_payload", Rack::Utils.parse_query(URI.parse(payload_headers.fetch("location")).query).fetch("error")
  end

  def test_oauth_proxy_callback_hides_corrupt_verification_state_errors
    auth = build_auth(
      database: nil,
      secondary_storage: OAuthProxySecondaryStorage.new,
      plugins: [BetterAuth::Plugins.oauth_proxy]
    )
    state = "corrupt-verification-state"
    auth.context.internal_adapter.create_verification_value(
      identifier: state,
      value: "{",
      expiresAt: Time.now + 600
    )
    profile = BetterAuth::Crypto.symmetric_encrypt(
      key: auth.context.secret,
      data: JSON.generate({
        userInfo: {id: "google-sub", email: "proxy@example.com", name: "Proxy User", emailVerified: true},
        account: {providerId: "google", accountId: "google-sub", accessToken: "access-token"},
        state: state,
        callbackURL: "/dashboard",
        errorURL: "/profile-error?source=corrupt",
        timestamp: (Time.now.to_f * 1000).to_i
      })
    )

    status, headers, = auth.api.oauth_proxy(query: {callbackURL: "/dashboard", profile: profile}, as_response: true)

    assert_equal 302, status
    error_uri = URI.parse(headers.fetch("location"))
    assert_equal "/profile-error", error_uri.path
    assert_equal({"source" => "corrupt", "error" => "state_mismatch"}, Rack::Utils.parse_query(error_uri.query))
    refute auth.context.internal_adapter.find_user_by_email("proxy@example.com")
    refute_includes headers.fetch("set-cookie", ""), "better-auth.session_token="
  end

  def test_oauth_proxy_callback_normalizes_failed_oauth_user_lookup_code
    auth = build_auth(
      database: nil,
      secondary_storage: OAuthProxySecondaryStorage.new,
      plugins: [BetterAuth::Plugins.oauth_proxy]
    )
    state = "failed-oauth-user-lookup"
    auth.context.internal_adapter.create_verification_value(
      identifier: state,
      value: JSON.generate({oauthState: state, expiresAt: Time.now.to_i + 600}),
      expiresAt: Time.now + 600
    )
    profile = BetterAuth::Crypto.symmetric_encrypt(
      key: auth.context.secret,
      data: JSON.generate({
        userInfo: {id: "google-sub", email: "lookup@example.com", name: "Lookup User", emailVerified: true},
        account: {providerId: "google", accountId: "google-sub", accessToken: "access-token"},
        state: state,
        callbackURL: "/dashboard",
        errorURL: "/profile-error?source=lookup",
        timestamp: (Time.now.to_f * 1000).to_i
      })
    )

    status, headers, = auth.context.internal_adapter.stub(:find_oauth_user, ->(*) { raise "database unavailable" }) do
      auth.api.oauth_proxy(query: {callbackURL: "/dashboard", profile: profile}, as_response: true)
    end

    assert_equal 302, status
    error_uri = URI.parse(headers.fetch("location"))
    assert_equal "/profile-error", error_uri.path
    assert_equal(
      {"source" => "lookup", "error" => "internal_server_error", "error_description" => "internal server error"},
      Rack::Utils.parse_query(error_uri.query)
    )
    refute auth.context.internal_adapter.find_user_by_email("lookup@example.com")
  end

  def test_database_state_packaging_failure_keeps_the_normal_sign_in_response
    auth = build_auth(
      base_url: "http://preview.local",
      database: nil,
      secondary_storage: OAuthProxySecondaryStorage.new,
      plugins: [BetterAuth::Plugins.oauth_proxy(current_url: "http://preview.local", production_url: "http://localhost:3000")]
    )

    status, _headers, body = auth.context.internal_adapter.stub(:find_verification_value, ->(*) { raise "secondary storage unavailable" }) do
      auth.call(oauth_proxy_rack_env(
        "POST",
        "/api/auth/sign-in/social",
        body: {provider: "google", callbackURL: "/dashboard"},
        host: "preview.local"
      ))
    end
    state = Rack::Utils.parse_query(URI.parse(JSON.parse(body.join).fetch("url")).query).fetch("state")

    assert_equal 200, status
    assert auth.context.internal_adapter.find_verification_value(state)
  end

  def test_oauth_proxy_callback_rejects_untrusted_callback_url
    auth = build_auth(trusted_origins: ["http://localhost:3000"], plugins: [BetterAuth::Plugins.oauth_proxy])

    error = assert_raises(BetterAuth::APIError) do
      auth.api.oauth_proxy(query: {callbackURL: "https://evil.example/dashboard"})
    end

    assert_equal 403, error.status_code
    assert_equal "Invalid callbackURL", error.message
  end

  def test_same_origin_sign_in_keeps_the_canonical_provider_redirect_uri
    auth = build_auth(plugins: [BetterAuth::Plugins.oauth_proxy(current_url: "http://localhost:3000", production_url: "http://localhost:3000")])

    result = auth.api.sign_in_social(body: {provider: "google", callbackURL: "/dashboard"})
    authorization_params = Rack::Utils.parse_query(URI.parse(result.fetch(:url)).query)

    assert_equal "http://localhost:3000/api/auth/callback/google", authorization_params.fetch("redirect_uri")
  end

  def test_proxy_preserves_production_url_path_in_social_redirect_uri
    auth = build_auth(
      base_url: "http://preview.local",
      plugins: [BetterAuth::Plugins.oauth_proxy(current_url: "http://preview.local", production_url: "https://login.example.com/auth")]
    )

    result = auth.api.sign_in_social(body: {provider: "google", callbackURL: "/dashboard"})
    authorization_params = Rack::Utils.parse_query(URI.parse(result.fetch(:url)).query)

    assert_equal "https://login.example.com/auth/api/auth/callback/google", authorization_params.fetch("redirect_uri")
  end

  def test_database_preview_state_survives_cookie_production_and_is_consumed_on_preview
    proxy_secret = "shared-oauth-proxy-secret-1234567890"
    preview = build_auth(
      base_url: "http://preview.local",
      secret: "preview-environment-secret-1234567890",
      database: nil,
      secondary_storage: OAuthProxySecondaryStorage.new,
      plugins: [
        BetterAuth::Plugins.oauth_proxy(
          current_url: "http://preview.local",
          production_url: "http://localhost:3000",
          secret: proxy_secret
        )
      ]
    )
    production = build_auth(
      base_url: "http://localhost:3000",
      secret: "production-environment-secret-1234567890",
      database: nil,
      plugins: [BetterAuth::Plugins.oauth_proxy(current_url: "http://preview.local", production_url: "http://localhost:3000", secret: proxy_secret)]
    )

    assert_equal "database", preview.context.options.account.fetch(:store_state_strategy)
    assert_equal "cookie", production.context.options.account.fetch(:store_state_strategy)

    sign_in_status, _sign_in_headers, sign_in_body = preview.call(oauth_proxy_rack_env(
      "POST",
      "/api/auth/sign-in/social",
      body: {provider: "google", callbackURL: "/dashboard"},
      host: "preview.local"
    ))
    authorization_params = Rack::Utils.parse_query(URI.parse(JSON.parse(sign_in_body.join).fetch("url")).query)
    proxy_state = authorization_params.fetch("state")
    state_package = JSON.parse(BetterAuth::Crypto.symmetric_decrypt(key: proxy_secret, data: proxy_state))
    state = state_package.fetch("state")

    assert_equal 200, sign_in_status
    assert_equal "http://localhost:3000/api/auth/callback/google", authorization_params.fetch("redirect_uri")
    assert preview.context.internal_adapter.find_verification_value(state)
    refute production.context.internal_adapter.find_verification_value(state)

    callback_status, callback_headers, = production.call(oauth_proxy_rack_env(
      "GET",
      "/api/auth/callback/google?#{URI.encode_www_form(code: "code", state: proxy_state)}",
      host: "localhost:3000"
    ))

    assert_equal 302, callback_status
    assert_match(%r{\Ahttp://preview\.local/api/auth/oauth-proxy-callback\?}, callback_headers.fetch("location"))
    refute production.context.internal_adapter.find_user_by_email("proxy@example.com")
    refute preview.context.internal_adapter.find_user_by_email("proxy@example.com")

    proxy_uri = URI.parse(callback_headers.fetch("location"))
    proxy_query = Rack::Utils.parse_query(proxy_uri.query)
    profile = JSON.parse(BetterAuth::Crypto.symmetric_decrypt(key: proxy_secret, data: proxy_query.fetch("profile")))

    assert_equal "http://preview.local", proxy_uri.origin
    assert_equal "/api/auth/oauth-proxy-callback", proxy_uri.path
    assert_equal({"id" => "google-sub", "email" => "proxy@example.com", "name" => "Proxy User", "emailVerified" => true}, profile.fetch("userInfo"))
    assert_equal({"providerId" => "google", "accountId" => "google-sub", "accessToken" => "access-token", "idToken" => "id-token"}, profile.fetch("account"))

    expired_profile = profile.merge("timestamp" => ((Time.now - 120).to_f * 1000).to_i)
    expired_query = proxy_query.merge("profile" => BetterAuth::Crypto.symmetric_encrypt(key: proxy_secret, data: JSON.generate(expired_profile)))
    expired_status, expired_headers, = preview.call(oauth_proxy_rack_env(
      "GET",
      "#{proxy_uri.path}?#{URI.encode_www_form(expired_query)}",
      host: "preview.local"
    ))

    assert_equal 302, expired_status
    assert_equal "payload_expired", Rack::Utils.parse_query(URI.parse(expired_headers.fetch("location")).query).fetch("error")
    assert preview.context.internal_adapter.find_verification_value(state)

    proxy_status, proxy_headers, = preview.call(oauth_proxy_rack_env(
      "GET",
      "#{proxy_uri.path}?#{URI.encode_www_form(proxy_query)}",
      host: "preview.local"
    ))

    assert_equal 302, proxy_status
    assert_equal "/dashboard", proxy_headers.fetch("location")
    assert preview.context.internal_adapter.find_user_by_email("proxy@example.com")
    refute preview.context.internal_adapter.find_verification_value(state)

    replay_status, replay_headers, = preview.call(oauth_proxy_rack_env(
      "GET",
      "#{proxy_uri.path}?#{URI.encode_www_form(proxy_query)}",
      host: "preview.local"
    ))

    assert_equal 302, replay_status
    assert_equal "state_mismatch", Rack::Utils.parse_query(URI.parse(replay_headers.fetch("location")).query).fetch("error")
  end

  def test_cookie_preview_state_uses_shared_proxy_secret_and_requires_its_oauth_state_cookie
    proxy_secret = "shared-oauth-proxy-secret-1234567890"
    preview = build_auth(
      base_url: "http://preview.local",
      secret: "preview-environment-secret-1234567890",
      database: nil,
      plugins: [BetterAuth::Plugins.oauth_proxy(current_url: "http://preview.local", production_url: "http://localhost:3000", secret: proxy_secret)]
    )
    production = build_auth(
      base_url: "http://localhost:3000",
      secret: "production-environment-secret-1234567890",
      database: nil,
      plugins: [BetterAuth::Plugins.oauth_proxy(current_url: "http://preview.local", production_url: "http://localhost:3000", secret: proxy_secret)]
    )

    sign_in_status, sign_in_headers, sign_in_body = preview.call(oauth_proxy_rack_env(
      "POST",
      "/api/auth/sign-in/social",
      body: {provider: "google", callbackURL: "/dashboard"},
      host: "preview.local"
    ))
    proxy_state = Rack::Utils.parse_query(URI.parse(JSON.parse(sign_in_body.join).fetch("url")).query).fetch("state")
    state_package = JSON.parse(BetterAuth::Crypto.symmetric_decrypt(key: proxy_secret, data: proxy_state))
    state = state_package.fetch("state")
    state_data = JSON.parse(BetterAuth::Crypto.symmetric_decrypt(key: proxy_secret, data: state_package.fetch("stateCookie")))

    assert_equal 200, sign_in_status
    assert_includes sign_in_headers.fetch("set-cookie"), "better-auth.oauth_state="
    assert_equal state, state_data.fetch("oauthState")

    callback_status, callback_headers, = production.call(oauth_proxy_rack_env(
      "GET",
      "/api/auth/callback/google?#{URI.encode_www_form(code: "code", state: proxy_state)}",
      host: "localhost:3000"
    ))
    proxy_uri = URI.parse(callback_headers.fetch("location"))
    proxy_query = Rack::Utils.parse_query(proxy_uri.query)

    assert_equal 302, callback_status
    assert_equal "http://preview.local", proxy_uri.origin

    missing_cookie_status, missing_cookie_headers, = preview.call(oauth_proxy_rack_env(
      "GET",
      "#{proxy_uri.path}?#{URI.encode_www_form(proxy_query)}",
      host: "preview.local"
    ))

    assert_equal 302, missing_cookie_status
    assert_equal "state_mismatch", Rack::Utils.parse_query(URI.parse(missing_cookie_headers.fetch("location")).query).fetch("error")
    refute preview.context.internal_adapter.find_user_by_email("proxy@example.com")

    proxy_status, proxy_headers, = preview.call(oauth_proxy_rack_env(
      "GET",
      "#{proxy_uri.path}?#{URI.encode_www_form(proxy_query)}",
      host: "preview.local",
      cookie: oauth_proxy_cookie_header(sign_in_headers.fetch("set-cookie"))
    ))

    assert_equal 302, proxy_status
    assert_equal "/dashboard", proxy_headers.fetch("location")
    assert preview.context.internal_adapter.find_user_by_email("proxy@example.com")
  end

  def test_generic_oauth_database_preview_state_survives_cookie_production_and_is_consumed_on_preview
    proxy_secret = "shared-oauth-proxy-secret-1234567890"
    preview = build_auth(
      base_url: "http://preview.local",
      secret: "preview-environment-secret-1234567890",
      database: nil,
      secondary_storage: OAuthProxySecondaryStorage.new,
      account: {store_account_cookie: true},
      plugins: [
        BetterAuth::Plugins.oauth_proxy(current_url: "http://preview.local", production_url: "http://localhost:3000", secret: proxy_secret),
        oauth_proxy_generic_oauth_plugin
      ]
    )
    production = build_auth(
      base_url: "http://localhost:3000",
      secret: "production-environment-secret-1234567890",
      database: nil,
      plugins: [
        BetterAuth::Plugins.oauth_proxy(current_url: "http://preview.local", production_url: "http://localhost:3000", secret: proxy_secret),
        oauth_proxy_generic_oauth_plugin
      ]
    )

    assert_equal "database", preview.context.options.account.fetch(:store_state_strategy)
    assert_equal "cookie", production.context.options.account.fetch(:store_state_strategy)

    sign_in_status, _sign_in_headers, sign_in_body = preview.call(oauth_proxy_rack_env(
      "POST",
      "/api/auth/sign-in/oauth2",
      body: {providerId: "custom", callbackURL: "/dashboard"},
      host: "preview.local"
    ))
    authorization_params = Rack::Utils.parse_query(URI.parse(JSON.parse(sign_in_body.join).fetch("url")).query)
    proxy_state = authorization_params.fetch("state")
    package = JSON.parse(BetterAuth::Crypto.symmetric_decrypt(key: proxy_secret, data: proxy_state))
    original_state = package.fetch("state")

    assert_equal 200, sign_in_status
    assert_equal "http://localhost:3000/api/auth/oauth2/callback/custom", authorization_params.fetch("redirect_uri")
    assert preview.context.internal_adapter.find_verification_value(original_state)
    refute production.context.internal_adapter.find_verification_value(original_state)

    callback_status, callback_headers, = production.call(oauth_proxy_rack_env(
      "GET",
      "/api/auth/oauth2/callback/custom?#{URI.encode_www_form(code: "oauth-code", state: proxy_state)}",
      host: "localhost:3000"
    ))

    assert_equal 302, callback_status
    refute production.context.internal_adapter.find_user_by_email("proxy-generic@example.com")
    proxy_uri = URI.parse(callback_headers.fetch("location"))
    proxy_query = Rack::Utils.parse_query(proxy_uri.query)

    proxy_status, proxy_headers, = preview.call(oauth_proxy_rack_env(
      "GET",
      "#{proxy_uri.path}?#{URI.encode_www_form(proxy_query)}",
      host: "preview.local"
    ))

    assert_equal 302, proxy_status
    assert_equal "/dashboard", proxy_headers.fetch("location")
    assert preview.context.internal_adapter.find_user_by_email("proxy-generic@example.com")
    refute preview.context.internal_adapter.find_verification_value(original_state)
    assert_includes proxy_headers.fetch("set-cookie"), "#{preview.context.auth_cookies[:account_data].name}="
  end

  def test_proxy_does_not_relabel_social_provider_key_errors_as_state_mismatch
    proxy_secret = "shared-oauth-proxy-secret-1234567890"
    preview = build_auth(
      base_url: "http://preview.local",
      database: nil,
      secondary_storage: OAuthProxySecondaryStorage.new,
      plugins: [BetterAuth::Plugins.oauth_proxy(current_url: "http://preview.local", production_url: "http://localhost:3000", secret: proxy_secret)]
    )
    production = build_auth(
      base_url: "http://localhost:3000",
      database: nil,
      social_providers: oauth_proxy_social_providers(get_user_info: ->(_tokens) { raise KeyError, "provider failure" }),
      plugins: [BetterAuth::Plugins.oauth_proxy(current_url: "http://preview.local", production_url: "http://localhost:3000", secret: proxy_secret)]
    )
    _status, _headers, sign_in_body = preview.call(oauth_proxy_rack_env(
      "POST",
      "/api/auth/sign-in/social",
      body: {provider: "google", callbackURL: "/dashboard"},
      host: "preview.local"
    ))
    proxy_state = Rack::Utils.parse_query(URI.parse(JSON.parse(sign_in_body.join).fetch("url")).query).fetch("state")

    error = assert_raises(KeyError) do
      production.call(oauth_proxy_rack_env(
        "GET",
        "/api/auth/callback/google?#{URI.encode_www_form(code: "code", state: proxy_state)}",
        host: "localhost:3000"
      ))
    end

    assert_equal "provider failure", error.message
  end

  private

  def oauth_proxy_rack_env(method, path, host:, body: nil, cookie: nil)
    path_info, query_string = path.split("?", 2)
    payload = body ? JSON.generate(body) : ""
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path_info,
      "QUERY_STRING" => query_string || "",
      "SERVER_NAME" => host.split(":").first,
      "SERVER_PORT" => host.split(":", 2).last || "80",
      "REMOTE_ADDR" => "127.0.0.1",
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(payload),
      "CONTENT_TYPE" => body ? "application/json" : nil,
      "CONTENT_LENGTH" => payload.bytesize.to_s,
      "HTTP_HOST" => host,
      "HTTP_ORIGIN" => "http://#{host}",
      "HTTP_COOKIE" => cookie
    }.compact
  end

  def build_auth(options = {})
    BetterAuth.auth({
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: :memory,
      email_and_password: {enabled: true},
      social_providers: oauth_proxy_social_providers
    }.merge(options))
  end

  def oauth_proxy_social_providers(get_user_info: ->(_tokens) { {user: {id: "google-sub", email: "proxy@example.com", name: "Proxy User", emailVerified: true}} })
    {
      google: {
        create_authorization_url: ->(data) { "https://accounts.google.com/o/oauth2/v2/auth?#{URI.encode_www_form(state: data[:state], redirect_uri: data[:redirect_uri])}" },
        validate_authorization_code: ->(_data) { {accessToken: "access-token", idToken: "id-token"} },
        get_user_info: get_user_info
      }
    }
  end

  def oauth_proxy_generic_oauth_plugin
    BetterAuth::Plugins.generic_oauth(
      config: [
        {
          provider_id: "custom",
          authorization_url: "https://provider.example.com/authorize",
          token_url: "https://provider.example.com/token",
          client_id: "client-id",
          get_token: ->(code:, **_data) {
            raise "unexpected code" unless code == "oauth-code"

            {accessToken: "generic-access-token", idToken: "generic-id-token", scopes: ["openid", "email"]}
          },
          get_user_info: ->(_tokens) { {id: "generic-sub", email: "proxy-generic@example.com", name: "Generic Proxy User", emailVerified: true} },
          override_user_info: true
        }
      ]
    )
  end

  def oauth_proxy_cookie_header(set_cookie)
    set_cookie.lines.filter_map do |line|
      line.split(";", 2).first if line.start_with?("better-auth.oauth_state=")
    end.join("; ")
  end

  class OAuthProxySecondaryStorage
    def initialize
      @data = {}
    end

    def get(key)
      @data[key]
    end

    def set(key, value, _ttl = nil)
      @data[key] = value
    end

    def delete(key)
      @data.delete(key)
    end

    def get_and_delete(key)
      @data.delete(key)
    end
  end
end
