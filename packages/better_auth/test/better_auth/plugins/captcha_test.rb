# frozen_string_literal: true

require "json"
require "stringio"
require_relative "../../test_helper"

class BetterAuthPluginsCaptchaTest < Minitest::Test
  SECRET = "phase-nine-captcha-secret-with-enough-entropy"

  def test_ignores_unprotected_endpoints_and_requires_response_on_default_endpoints
    auth = build_auth(provider: "cloudflare-turnstile", verifier: ->(_params) { {success: true} })

    ok_status, = auth.call(rack_env("GET", "/api/auth/ok"))
    assert_equal 200, ok_status

    status, _headers, body = auth.call(rack_env("POST", "/api/auth/sign-in/email", body: {email: "a@example.com", password: "password123"}))
    assert_equal 400, status
    error = JSON.parse(body.join)
    assert_equal "MISSING_RESPONSE", error.fetch("code")
    assert_equal "Missing CAPTCHA response", error.fetch("message")
  end

  def test_default_endpoints_require_captcha_response
    auth = build_auth(provider: "cloudflare-turnstile", verifier: ->(_params) { {success: true} })

    [
      ["/api/auth/sign-up/email", {email: "signup-default@example.com", password: "password123", name: "Signup"}],
      ["/api/auth/sign-in/email", {email: "signin-default@example.com", password: "password123"}],
      ["/api/auth/request-password-reset", {email: "reset-default@example.com"}]
    ].each do |path, request_body|
      status, _headers, body = auth.call(rack_env("POST", path, body: request_body))

      assert_equal 400, status, path
      assert_equal "MISSING_RESPONSE", JSON.parse(body.join).fetch("code"), path
    end
  end

  def test_custom_endpoints_replace_default_protected_endpoints
    auth = build_auth(
      provider: "cloudflare-turnstile",
      endpoints: ["/sign-up/email"],
      verifier: ->(_params) { {success: true} }
    )
    auth.api.sign_up_email(body: {email: "custom-endpoint@example.com", password: "password123", name: "Custom"})

    default_status, = auth.call(rack_env(
      "POST",
      "/api/auth/sign-in/email",
      body: {email: "custom-endpoint@example.com", password: "password123"}
    ))
    assert_equal 200, default_status

    custom_status, _headers, custom_body = auth.call(rack_env(
      "POST",
      "/api/auth/sign-up/email",
      body: {email: "custom-protected@example.com", password: "password123", name: "Protected"}
    ))
    assert_equal 400, custom_status
    assert_equal "MISSING_RESPONSE", JSON.parse(custom_body.join).fetch("code")
  end

  def test_cloudflare_turnstile_posts_json_and_allows_success
    observed = nil
    auth = build_auth(
      provider: "cloudflare-turnstile",
      verifier: ->(params) {
        observed = params
        {success: true}
      }
    )
    auth.api.sign_up_email(body: {email: "captcha@example.com", password: "password123", name: "Captcha"})

    status, _headers, = auth.call(rack_env(
      "POST",
      "/api/auth/sign-in/email",
      body: {email: "captcha@example.com", password: "password123"},
      headers: {"HTTP_X_CAPTCHA_RESPONSE" => "captcha-token", "REMOTE_ADDR" => "203.0.113.10"}
    ))

    assert_equal 200, status
    assert_equal "application/json", observed.fetch(:content_type)
    assert_equal "203.0.113.10", observed.fetch(:payload).fetch("remoteip")
  end

  def test_captcha_uses_configured_request_ip_options
    observed = nil
    auth = build_auth(
      provider: "google-recaptcha",
      advanced: {
        ip_address: {
          ip_address_headers: ["x-client-ip", "x-forwarded-for"]
        }
      },
      verifier: ->(params) {
        observed = params
        {success: true}
      }
    )
    auth.api.sign_up_email(body: {email: "advanced-ip@example.com", password: "password123", name: "IP"})

    status, = auth.call(rack_env(
      "POST",
      "/api/auth/sign-in/email",
      body: {email: "advanced-ip@example.com", password: "password123"},
      headers: {
        "HTTP_X_CAPTCHA_RESPONSE" => "captcha-token",
        "HTTP_X_CLIENT_IP" => "203.0.113.77",
        "HTTP_X_FORWARDED_FOR" => "198.51.100.10"
      }
    ))

    assert_equal 200, status
    assert_equal "203.0.113.77", observed.fetch(:payload).fetch("remoteip")
  end

  def test_google_recaptcha_enforces_score_and_form_encoding
    auth = build_auth(
      provider: "google-recaptcha",
      min_score: 0.8,
      verifier: ->(params) {
        assert_equal "application/x-www-form-urlencoded", params.fetch(:content_type)
        {success: true, score: 0.2}
      }
    )
    auth.api.sign_up_email(body: {email: "google-captcha@example.com", password: "password123", name: "Captcha"})

    status, _headers, body = auth.call(rack_env(
      "POST",
      "/api/auth/sign-in/email",
      body: {email: "google-captcha@example.com", password: "password123"},
      headers: {"HTTP_X_CAPTCHA_RESPONSE" => "low-score-token"}
    ))

    assert_equal 403, status
    error = JSON.parse(body.join)
    assert_equal "VERIFICATION_FAILED", error.fetch("code")
    assert_equal "Captcha verification failed", error.fetch("message")
  end

  def test_hcaptcha_and_captchafox_include_site_key_and_expected_remote_ip_key
    hcaptcha_seen = nil
    hcaptcha = build_auth(provider: "hcaptcha", site_key: "site", verifier: ->(params) {
      hcaptcha_seen = params
      {success: true}
    })
    hcaptcha.api.sign_up_email(body: {email: "hcaptcha@example.com", password: "password123", name: "Captcha"})
    assert_equal 200, hcaptcha.call(rack_env(
      "POST",
      "/api/auth/sign-in/email",
      body: {email: "hcaptcha@example.com", password: "password123"},
      headers: {"HTTP_X_CAPTCHA_RESPONSE" => "token", "REMOTE_ADDR" => "198.51.100.10"}
    )).first
    assert_equal "site", hcaptcha_seen.fetch(:payload).fetch("sitekey")
    assert_equal "198.51.100.10", hcaptcha_seen.fetch(:payload).fetch("remoteip")

    fox_seen = nil
    fox = build_auth(provider: "captchafox", site_key: "fox-site", verifier: ->(params) {
      fox_seen = params
      {success: true}
    })
    fox.api.sign_up_email(body: {email: "fox@example.com", password: "password123", name: "Captcha"})
    assert_equal 200, fox.call(rack_env(
      "POST",
      "/api/auth/sign-in/email",
      body: {email: "fox@example.com", password: "password123"},
      headers: {"HTTP_X_CAPTCHA_RESPONSE" => "token", "REMOTE_ADDR" => "198.51.100.11"}
    )).first
    assert_equal "fox-site", fox_seen.fetch(:payload).fetch("sitekey")
    assert_equal "198.51.100.11", fox_seen.fetch(:payload).fetch("remoteIp")
  end

  def test_site_key_payload_is_restricted_to_hcaptcha_and_captchafox
    providers = {
      "cloudflare-turnstile" => false,
      "google-recaptcha" => false,
      "hcaptcha" => true,
      "captchafox" => true
    }

    providers.each do |provider, expected_sitekey|
      observed = nil
      auth = build_auth(provider: provider, site_key: "site-key", verifier: ->(params) {
        observed = params
        {success: true}
      })
      email = "#{provider.tr("-", "_")}@example.com"
      auth.api.sign_up_email(body: {email: email, password: "password123", name: provider})

      status, = auth.call(rack_env(
        "POST",
        "/api/auth/sign-in/email",
        body: {email: email, password: "password123"},
        headers: {"HTTP_X_CAPTCHA_RESPONSE" => "token"}
      ))

      assert_equal 200, status, provider
      assert_equal expected_sitekey, observed.fetch(:payload).key?("sitekey"), provider
    end
  end

  def test_provider_matrix_allows_success_and_builds_expected_payloads
    expected = {
      "cloudflare-turnstile" => ["application/json", "remoteip"],
      "google-recaptcha" => ["application/x-www-form-urlencoded", "remoteip"],
      "hcaptcha" => ["application/x-www-form-urlencoded", "remoteip"],
      "captchafox" => ["application/x-www-form-urlencoded", "remoteIp"]
    }

    expected.each do |provider, (content_type, remote_key)|
      observed = nil
      auth = build_auth(provider: provider, site_key: "matrix-site-key", verifier: ->(params) {
        observed = params
        {success: true}
      })
      email = "success-#{provider}@example.com"
      auth.api.sign_up_email(body: {email: email, password: "password123", name: provider})

      status, = auth.call(rack_env(
        "POST",
        "/api/auth/sign-in/email",
        body: {email: email, password: "password123"},
        headers: {"HTTP_X_CAPTCHA_RESPONSE" => "matrix-token", "REMOTE_ADDR" => "203.0.113.20"}
      ))

      assert_equal 200, status, provider
      assert_equal content_type, observed.fetch(:content_type), provider
      assert_equal "https://captcha.test/siteverify", observed.fetch(:url), provider
      assert_equal "secret", observed.fetch(:payload).fetch("secret"), provider
      assert_equal "matrix-token", observed.fetch(:payload).fetch("response"), provider
      assert_equal "203.0.113.20", observed.fetch(:payload).fetch(remote_key), provider
    end
  end

  def test_provider_matrix_returns_verification_failed_code
    %w[cloudflare-turnstile google-recaptcha hcaptcha captchafox].each do |provider|
      auth = build_auth(provider: provider, verifier: ->(_params) { {success: false} })
      email = "failed-#{provider}@example.com"
      auth.api.sign_up_email(body: {email: email, password: "password123", name: provider})

      status, _headers, body = auth.call(rack_env(
        "POST",
        "/api/auth/sign-in/email",
        body: {email: email, password: "password123"},
        headers: {"HTTP_X_CAPTCHA_RESPONSE" => "invalid-token"}
      ))

      assert_equal 403, status, provider
      assert_equal "VERIFICATION_FAILED", JSON.parse(body.join).fetch("code"), provider
    end
  end

  def test_provider_matrix_returns_unknown_error_code_on_service_error
    %w[cloudflare-turnstile google-recaptcha hcaptcha captchafox].each do |provider|
      auth = build_auth(provider: provider, verifier: ->(_params) { raise "service down" })

      status, _headers, body = auth.call(rack_env(
        "POST",
        "/api/auth/sign-in/email",
        body: {email: "service-#{provider}@example.com", password: "password123"},
        headers: {"HTTP_X_CAPTCHA_RESPONSE" => "token"}
      ))

      assert_equal 500, status, provider
      assert_equal "UNKNOWN_ERROR", JSON.parse(body.join).fetch("code"), provider
    end
  end

  def test_service_failure_returns_unknown_error
    auth = build_auth(provider: "cloudflare-turnstile", verifier: ->(_params) { raise "boom" })

    status, _headers, body = auth.call(rack_env(
      "POST",
      "/api/auth/sign-in/email",
      body: {email: "missing@example.com", password: "password123"},
      headers: {"HTTP_X_CAPTCHA_RESPONSE" => "token"}
    ))

    assert_equal 500, status
    error = JSON.parse(body.join)
    assert_equal "UNKNOWN_ERROR", error.fetch("code")
    assert_equal "Something went wrong", error.fetch("message")
  end

  def test_missing_secret_key_returns_unknown_error
    auth = build_auth(provider: "cloudflare-turnstile", secret_key: "", verifier: ->(_params) { {success: true} })

    status, _headers, body = auth.call(rack_env(
      "POST",
      "/api/auth/sign-in/email",
      body: {email: "missing-secret@example.com", password: "password123"},
      headers: {"HTTP_X_CAPTCHA_RESPONSE" => "token"}
    ))

    assert_equal 500, status
    assert_equal "UNKNOWN_ERROR", JSON.parse(body.join).fetch("code")
  end

  def build_auth(options)
    BetterAuth.auth(
      secret: SECRET,
      email_and_password: {enabled: true},
      advanced: options[:advanced] || {},
      plugins: [
        BetterAuth::Plugins.captcha(
          provider: options.fetch(:provider),
          secret_key: options.fetch(:secret_key, "secret"),
          site_key: options[:site_key],
          min_score: options[:min_score],
          endpoints: options[:endpoints],
          site_verify_url_override: options[:site_verify_url_override] || "https://captcha.test/siteverify",
          verifier: options.fetch(:verifier)
        )
      ]
    )
  end

  def rack_env(method, path, body: nil, headers: {})
    payload = body ? JSON.generate(body) : ""
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => "",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "3000",
      "REMOTE_ADDR" => headers.fetch("REMOTE_ADDR", "127.0.0.1"),
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(payload),
      "CONTENT_TYPE" => body ? "application/json" : nil,
      "CONTENT_LENGTH" => payload.bytesize.to_s
    }.merge(headers).compact
  end
end
