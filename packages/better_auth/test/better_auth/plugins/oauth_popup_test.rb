# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "rack/mock"
require "uri"
require_relative "../../test_helper"

class BetterAuthPluginsOAuthPopupTest < Minitest::Test
  SECRET = "oauth-popup-secret-with-enough-entropy-123"
  BASE_URL = "http://localhost:3000"
  POPUP_ORIGIN = "https://app.example.com"
  BetterAuth::Plugins.oauth_popup

  def test_completion_script_hash_matches_actual_script_bytes
    assert_equal "sha256-tIo2K8VBC9SnhvdZ+9GsGkQoZm+jm/JcxL+d+i8b8KQ=", BetterAuth::Plugins::OAUTH_POPUP_SCRIPT_CSP_HASH
    expected_policy = "default-src 'none'; script-src '#{BetterAuth::Plugins::OAUTH_POPUP_SCRIPT_CSP_HASH}'; base-uri 'none'"

    auth = build_generic_auth(provider_overrides: {authorization_url: nil})
    status, headers, body = popup_start(
      auth,
      popupNonce: "</script><script>alert(1)</script>\u2028\u2029"
    )
    source = body.join
    executable_script = source.match(%r{<script>(.*?)</script>}m)&.captures&.first
    emitted_hash = "sha256-#{Base64.strict_encode64(Digest::SHA256.digest(executable_script))}"

    assert_equal 200, status
    assert_equal BetterAuth::Plugins::OAUTH_POPUP_COMPLETE_SCRIPT, executable_script
    assert_equal BetterAuth::Plugins::OAUTH_POPUP_SCRIPT_CSP_HASH, emitted_hash
    assert_equal expected_policy, headers.fetch("content-security-policy")
    assert_equal 1, source.scan("<script>").length
    refute_includes source, "</script><script>alert(1)</script>"
    refute_includes source, "\u2028"
    refute_includes source, "\u2029"
    assert_includes source, "\\u003c/script>\\u003cscript>alert(1)\\u003c/script>"
  end

  def test_built_in_start_uses_confidential_opaque_state_for_database_and_cookie_strategies
    [nil, "cookie"].each do |strategy|
      captured = nil
      auth = build_builtin_auth(state_strategy: strategy) do |data|
        captured = data
        "https://provider.example/authorize?#{URI.encode_www_form(state: data.fetch(:state))}"
      end

      status, headers, = popup_start(auth, provider: "github", scopes: "profile,email")
      marker = cookie_line(headers, popup_cookie_name(auth))
      state = captured.fetch(:state)
      state_data = stored_oauth_state(auth, headers, state, strategy)

      assert_equal 302, status
      assert marker
      assert_includes marker, "Max-Age=600"
      assert_equal(
        {"popupOrigin" => POPUP_ORIGIN, "popupNonce" => "nonce-1"},
        signed_cookie_payload(marker, popup_cookie_name(auth))
      )
      assert_equal 32, state.length
      refute_includes state, captured.fetch(:codeVerifier)
      assert_nil BetterAuth::Crypto.verify_jwt(state, SECRET)
      assert_equal 128, captured.fetch(:codeVerifier).length
      assert_equal ["profile", "email"], captured.fetch(:scopes)
      assert_equal "#{BASE_URL}/api/auth/callback/github", captured.fetch(:redirectURI)
      assert_equal "#{BASE_URL}/api/auth", state_data.fetch("callbackURL")
      assert_equal captured.fetch(:codeVerifier), state_data.fetch("codeVerifier")
      assert_equal state, state_data.fetch("oauthState")
      assert_in_delta Time.now.to_i + 600, state_data.fetch("expiresAt"), 2
    end
  end

  def test_successful_callback_preserves_cookies_expires_marker_and_targets_exact_origin
    auth = build_generic_auth
    _start_status, start_headers, = popup_start(auth, popupNonce: "nonce-1", callbackURL: "/dashboard")
    state = authorization_params(start_headers).fetch("state")

    status, headers, body = popup_callback(auth, start_headers, state: state)
    data = completion_data(body)
    cookies = BetterAuth::Cookies.split_set_cookie_header(headers.fetch("set-cookie"))

    assert_equal 200, status
    assert_equal "text/html; charset=utf-8", headers.fetch("content-type")
    assert_equal "no-store", headers.fetch("cache-control")
    assert_equal "no-cache", headers.fetch("pragma")
    refute headers.key?("expires")
    refute headers.key?("location")
    assert cookies.any? { |line| line.start_with?("#{auth.context.auth_cookies[:session_token].name}=") }
    assert cookies.any? { |line| line.start_with?("#{auth.context.auth_cookies[:session_data].name}=") }
    assert cookies.any? { |line| line.start_with?("#{popup_cookie_name(auth)}=") && line.match?(/Max-Age=0/i) }
    assert_equal "better-auth:oauth-popup", data.fetch("type")
    assert_equal POPUP_ORIGIN, data.fetch("targetOrigin")
    assert_equal "nonce-1", data.fetch("nonce")
    assert_equal "/dashboard", data.fetch("redirectTo")
    session_cookie = cookies.reverse.find { |line| line.start_with?("#{auth.context.auth_cookies[:session_token].name}=") }
    expected_token = URI.decode_uri_component(BetterAuth::Cookies.parse_set_cookie(session_cookie).fetch(:value))
    assert_equal expected_token, data.fetch("token")
    refute data.key?("error")
  end

  def test_completion_token_authenticates_through_bearer
    auth = build_generic_auth
    _start_status, start_headers, = popup_start(auth)
    state = authorization_params(start_headers).fetch("state")
    _status, _headers, body = popup_callback(auth, start_headers, state: state)

    session = auth.api.get_session(headers: {"authorization" => "Bearer #{completion_data(body).fetch("token")}"})

    assert_equal "popup@example.com", session.fetch(:user).fetch("email")
  end

  def test_builtin_http_callback_completes_popup_and_preserves_other_after_hook_cookies_in_both_orders
    %i[popup_first popup_last].each do |plugin_order|
      auth = build_builtin_auth(last_login_method: true, plugin_order: plugin_order) do |data|
        "https://provider.example/authorize?#{URI.encode_www_form(state: data.fetch(:state))}"
      end
      _start_status, start_headers, = popup_start(auth, provider: "github", callbackURL: "/dashboard")
      state = authorization_params(start_headers).fetch("state")
      query = URI.encode_www_form(code: "oauth-code", state: state)

      status, headers, body = auth.call(
        rack_env(
          "GET",
          "/api/auth/callback/github?#{query}",
          cookie: cookie_header(start_headers.fetch("set-cookie"))
        )
      )
      cookies = BetterAuth::Cookies.split_set_cookie_header(headers.fetch("set-cookie"))
      token = completion_data(body).fetch("token")
      session = auth.api.get_session(headers: {"authorization" => "Bearer #{token}"})

      assert_equal 200, status
      refute headers.key?("location")
      assert_equal "/dashboard", completion_data(body).fetch("redirectTo")
      assert_equal "github@example.com", session.fetch(:user).fetch("email")
      assert cookies.any? { |line| line.start_with?("#{auth.context.auth_cookies[:session_token].name}=") }
      assert cookies.any? { |line| line.start_with?("#{auth.context.auth_cookies[:session_data].name}=") }
      assert cookies.any? { |line| line.start_with?("better-auth.last_used_login_method=github") }
      assert marker_expired?(auth, headers.fetch("set-cookie"))
    end
  end

  def test_builtin_new_user_popup_completes_with_new_user_redirect
    auth = build_builtin_auth do |data|
      "https://provider.example/authorize?#{URI.encode_www_form(state: data.fetch(:state))}"
    end
    _start_status, start_headers, = popup_start(
      auth,
      provider: "github",
      callbackURL: "/dashboard",
      newUserCallbackURL: "/welcome"
    )
    state = authorization_params(start_headers).fetch("state")

    status, headers, body = auth.call(
      rack_env(
        "GET",
        "/api/auth/callback/github?#{URI.encode_www_form(code: "oauth-code", state: state)}",
        cookie: cookie_header(start_headers.fetch("set-cookie"))
      )
    )

    assert_equal 200, status
    refute headers.key?("location")
    assert_equal "/welcome", completion_data(body).fetch("redirectTo")
  end

  def test_non_popup_callback_remains_normal_redirect_byte_for_byte
    auth = build_generic_auth
    status, headers, body = auth.api.sign_in_with_oauth2(
      body: {providerId: "custom", callbackURL: "/dashboard"},
      as_response: true
    )
    state = Rack::Utils.parse_query(URI.parse(JSON.parse(body.join).fetch("url")).query).fetch("state")

    callback_status, callback_headers, callback_body = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))},
      as_response: true
    )

    assert_equal 200, status
    assert_equal 302, callback_status
    assert_equal "/dashboard", callback_headers.fetch("location")
    assert_equal [{"code" => "FOUND", "message" => "Redirect"}], callback_body.map { |entry| JSON.parse(entry) }
  end

  def test_provider_error_and_description_are_relayed_to_opener
    auth = build_generic_auth
    _start_status, start_headers, = popup_start(auth, errorCallbackURL: "/error")
    state = authorization_params(start_headers).fetch("state")
    description = "</script><script>alert(2)</script>\u2028\u2029"
    query = {state: state, error: "access_denied", error_description: description}

    status, headers, body = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: query,
      headers: {"cookie" => cookie_header(start_headers.fetch("set-cookie"))},
      as_response: true
    )

    assert_equal 200, status
    refute headers.key?("location")
    data = completion_data(body)
    assert_equal({"code" => "access_denied", "description" => description}, data.fetch("error"))
    refute data.key?("token")
    refute data.key?("redirectTo")
    refute_includes body.join, "</script><script>alert(2)</script>"
    refute_includes body.join, "\u2028"
    refute_includes body.join, "\u2029"
  end

  def test_known_provider_api_error_during_authorization_url_returns_safe_completion
    auth = build_generic_auth(provider_overrides: {authorization_url: nil})

    status, headers, body = popup_start(auth)

    assert_equal 200, status
    assert_equal "text/html; charset=utf-8", headers.fetch("content-type")
    refute headers.key?("location")
    assert_equal "popup_sign_in_failed", completion_data(body).dig("error", "code")
    refute cookie_line(headers, popup_cookie_name(auth))
  end

  def test_generic_database_state_creation_failure_does_not_emit_insecure_authorization_url
    auth = build_generic_auth

    status, headers, body = auth.context.internal_adapter.stub(:create_verification_value, nil) do
      popup_start(auth)
    end

    assert_equal 200, status
    refute headers.key?("location")
    assert_equal "popup_sign_in_failed", completion_data(body).dig("error", "code")
    refute_includes body.join, "https://provider.example.com/authorize"
  end

  def test_unknown_provider_returns_safe_completion_without_marker
    auth = build_generic_auth
    status, headers, body = popup_start(auth, provider: "missing")

    assert_equal 200, status
    assert_equal "provider_not_found", completion_data(body).dig("error", "code")
    refute BetterAuth::Cookies.split_set_cookie_header(headers["set-cookie"]).any? { |line| line.start_with?("#{popup_cookie_name(auth)}=") }
  end

  def test_additional_data_preserves_exact_public_shape_and_cannot_replace_only_canonical_internal_state
    captured = nil
    auth = build_builtin_auth do |data|
      captured = data
      "https://provider.example/authorize?#{URI.encode_www_form(state: data.fetch(:state))}"
    end
    injected = {
      callbackURL: "https://evil.example/callback",
      callback_url: "kept-alias",
      errorURL: "https://evil.example/error",
      newUserURL: "https://evil.example/new",
      requestSignUp: false,
      codeVerifier: "attacker-verifier",
      code_verifier: "attacker-verifier-2",
      expiresAt: 1,
      expires_at: 1,
      link: {userId: "victim"},
      oauthState: "attacker-state",
      userId: "kept-user",
      accountId: "kept-account",
      tenantID: "acme",
      nestedValue: {"camelCaseKey" => "kept", "snake_key" => {"UPPERKey" => true}}
    }

    status, = popup_start(
      auth,
      provider: "github",
      callbackURL: "/dashboard",
      errorCallbackURL: "/error",
      newUserCallbackURL: "/welcome",
      requestSignUp: "true",
      additionalData: JSON.generate(injected)
    )
    state = stored_oauth_state(auth, nil, captured.fetch(:state), nil)

    assert_equal 302, status
    assert_equal "/dashboard", state.fetch("callbackURL")
    assert_equal "/error", state.fetch("errorURL")
    assert_equal "/welcome", state.fetch("newUserURL")
    assert_equal true, state.fetch("requestSignUp")
    assert_equal captured.fetch(:codeVerifier), state.fetch("codeVerifier")
    assert_equal "kept-user", state.fetch("userId")
    assert_equal "kept-account", state.fetch("accountId")
    assert_equal "kept-alias", state.fetch("callback_url")
    assert_equal "acme", state.fetch("tenantID")
    assert_equal({"camelCaseKey" => "kept", "snake_key" => {"UPPERKey" => true}}, state.fetch("nestedValue"))
    refute state.key?("link")
    refute_equal 1, state["expiresAt"]
    refute_equal "attacker-state", state["oauthState"]
  end

  def test_builtin_callback_consumes_state_and_rejects_replay_for_database_and_cookie_strategies
    [nil, "cookie"].each do |strategy|
      auth = build_builtin_auth(state_strategy: strategy) do |data|
        "https://provider.example/authorize?#{URI.encode_www_form(state: data.fetch(:state))}"
      end
      _start_status, start_headers, = popup_start(auth, provider: "github", callbackURL: "/dashboard")
      state = authorization_params(start_headers).fetch("state")
      request_cookie = cookie_header(start_headers.fetch("set-cookie"))
      state_cookie_name = auth.context.create_auth_cookie((strategy == "cookie") ? "oauth_state" : "state").name
      failed_cookie = if strategy == "cookie"
        request_cookie
      else
        cookie_header_without(request_cookie, state_cookie_name)
      end
      failed_state = (strategy == "cookie") ? "#{state}-wrong" : state

      failed_status, failed_headers, failed_body = auth.call(
        rack_env("GET", "/api/auth/callback/github?#{URI.encode_www_form(code: "oauth-code", state: failed_state)}", cookie: failed_cookie)
      )

      assert_equal 200, failed_status
      assert_equal "state_mismatch", completion_data(failed_body).dig("error", "code")
      refute cookie_expired?(failed_headers["set-cookie"], state_cookie_name)

      status, callback_headers, body = auth.call(
        rack_env("GET", "/api/auth/callback/github?#{URI.encode_www_form(code: "oauth-code", state: state)}", cookie: request_cookie)
      )

      assert_equal 200, status
      assert_equal "/dashboard", completion_data(body).fetch("redirectTo")
      assert_state_cookie_expired(auth, callback_headers, strategy)

      replay_cookie = cookie_header(callback_headers.fetch("set-cookie"))
      replay_status, replay_headers, = auth.call(
        rack_env("GET", "/api/auth/callback/github?#{URI.encode_www_form(code: "oauth-code", state: state)}", cookie: replay_cookie)
      )

      assert_equal 302, replay_status
      assert_includes replay_headers.fetch("location"), "error=state_mismatch"
      refute replay_headers.fetch("set-cookie", "").include?(auth.context.auth_cookies[:session_token].name)
    end
  end

  def test_cookie_state_decrypt_failure_does_not_expire_state_or_destroy_original_flow
    auth = build_builtin_auth(state_strategy: "cookie") do |data|
      "https://provider.example/authorize?#{URI.encode_www_form(state: data.fetch(:state))}"
    end
    _start_status, start_headers, = popup_start(auth, provider: "github", callbackURL: "/dashboard")
    state = authorization_params(start_headers).fetch("state")
    request_cookie = cookie_header(start_headers.fetch("set-cookie"))
    state_cookie_name = auth.context.create_auth_cookie("oauth_state").name
    corrupted_cookie = request_cookie.sub(/#{Regexp.escape(state_cookie_name)}=[^;]*/, "#{state_cookie_name}=not-encrypted")

    failed_status, failed_headers, failed_body = auth.call(
      rack_env("GET", "/api/auth/callback/github?#{URI.encode_www_form(code: "oauth-code", state: state)}", cookie: corrupted_cookie)
    )

    assert_equal 200, failed_status
    assert_equal "state_invalid", completion_data(failed_body).dig("error", "code")
    refute cookie_expired?(failed_headers["set-cookie"], state_cookie_name)

    status, _headers, body = auth.call(
      rack_env("GET", "/api/auth/callback/github?#{URI.encode_www_form(code: "oauth-code", state: state)}", cookie: request_cookie)
    )

    assert_equal 200, status
    assert_equal "/dashboard", completion_data(body).fetch("redirectTo")
  end

  def test_builtin_callback_rejects_expired_opaque_state_with_recovered_error_url
    [nil, "cookie"].each do |strategy|
      exchanged = false
      auth = build_builtin_auth(
        state_strategy: strategy,
        validate_authorization_code: ->(_data) { exchanged = true }
      ) { |_data| raise "unused" }
      ctx = callback_hook_context(auth, cookie: "", location: "/unused")
      state = BetterAuth::OAuthState.generate(
        ctx,
        "callbackURL" => "/dashboard",
        "errorURL" => "/expired-error",
        "codeVerifier" => "v" * 128,
        "expiresAt" => Time.now.to_i - 1
      )

      status, headers, = auth.api.callback_oauth(
        params: {providerId: "github"},
        query: {state: state, code: "oauth-code"},
        headers: {"cookie" => cookie_header(ctx.response_headers.fetch("set-cookie"))},
        as_response: true
      )

      assert_equal 302, status
      assert_equal "/expired-error?error=state_mismatch", headers.fetch("location")
      refute exchanged
    end
  end

  def test_builtin_provider_error_consumes_state_before_redirect_and_blocks_code_replay
    auth = build_builtin_auth(state_strategy: nil) do |data|
      "https://provider.example/authorize?#{URI.encode_www_form(state: data.fetch(:state))}"
    end
    _start_status, start_headers, = popup_start(auth, provider: "github", errorCallbackURL: "/popup-error")
    state = authorization_params(start_headers).fetch("state")
    request_cookie = cookie_header(start_headers.fetch("set-cookie"))

    status, headers, body = auth.call(
      rack_env("GET", "/api/auth/callback/github?#{URI.encode_www_form(state: state, error: "access_denied")}", cookie: request_cookie)
    )

    assert_equal 200, status
    assert_equal "access_denied", completion_data(body).dig("error", "code")
    refute headers.key?("location")

    replay_status, replay_headers, replay_body = auth.call(
      rack_env("GET", "/api/auth/callback/github?#{URI.encode_www_form(state: state, code: "oauth-code")}", cookie: request_cookie)
    )

    assert_equal 200, replay_status
    refute replay_headers.key?("location")
    assert_equal "state_mismatch", completion_data(replay_body).dig("error", "code")
    refute replay_headers.fetch("set-cookie", "").include?(auth.context.auth_cookies[:session_token].name)
  end

  def test_builtin_token_exchange_exception_becomes_popup_invalid_code_completion
    auth = build_builtin_auth(validate_authorization_code: ->(_data) { raise "provider exploded" }) do |data|
      "https://provider.example/authorize?#{URI.encode_www_form(state: data.fetch(:state))}"
    end
    _start_status, start_headers, = popup_start(auth, provider: "github", errorCallbackURL: "/popup-error")
    state = authorization_params(start_headers).fetch("state")

    status, headers, body = auth.call(
      rack_env(
        "GET",
        "/api/auth/callback/github?#{URI.encode_www_form(state: state, code: "oauth-code")}",
        cookie: cookie_header(start_headers.fetch("set-cookie"))
      )
    )

    data = completion_data(body)
    assert_equal 200, status
    refute headers.key?("location")
    assert_equal "invalid_code", data.dig("error", "code")
    refute data.key?("token")
    assert marker_expired?(auth, headers.fetch("set-cookie"))
  end

  def test_completion_accepts_session_cookie_without_max_age
    auth = build_generic_auth
    _start_status, start_headers, = popup_start(auth)
    ctx = callback_hook_context(
      auth,
      cookie: cookie_header(start_headers.fetch("set-cookie")),
      location: "/dashboard"
    )
    token = "session-token.signature"
    ctx.response_headers["set-cookie"] = "#{auth.context.auth_cookies[:session_token].name}=#{token}; Path=/; HttpOnly"

    result = BetterAuth::Plugins.oauth_popup_after_callback(ctx)
    data = completion_data(result.response)

    assert_equal token, data.fetch("token")
    assert_equal "/dashboard", data.fetch("redirectTo")
    refute data.key?("error")
  end

  def test_start_query_contract_rejects_missing_or_non_string_values
    auth = build_generic_auth
    [
      {},
      {provider: "custom"},
      {provider: 123, popupOrigin: POPUP_ORIGIN},
      {provider: "custom", popupOrigin: POPUP_ORIGIN, popupNonce: false},
      {provider: "custom", popupOrigin: POPUP_ORIGIN, callbackURL: []},
      {provider: "custom", popupOrigin: POPUP_ORIGIN, errorCallbackURL: {}},
      {provider: "custom", popupOrigin: POPUP_ORIGIN, newUserCallbackURL: true},
      {provider: "custom", popupOrigin: POPUP_ORIGIN, scopes: ["email"]},
      {provider: "custom", popupOrigin: POPUP_ORIGIN, requestSignUp: true},
      {provider: "custom", popupOrigin: POPUP_ORIGIN, additionalData: {tenant: "acme"}}
    ].each do |query|
      status, _headers, body = auth.api.oauth_popup_start(query: query, as_response: true)

      assert_equal 400, status, query.inspect
      assert_equal BetterAuth::BASE_ERROR_CODES["VALIDATION_ERROR"], JSON.parse(body.join).fetch("message")
    end
  end

  def test_hidden_start_endpoint_catalogs_its_query_contract
    endpoint = build_generic_auth.api.endpoints.fetch(:oauth_popup_start)
    parameters = endpoint.metadata.dig(:openapi, :parameters)

    assert_equal true, endpoint.metadata.fetch(:hide)
    assert_equal(
      %w[additionalData callbackURL errorCallbackURL newUserCallbackURL popupNonce popupOrigin provider requestSignUp scopes],
      parameters.map { |parameter| parameter.fetch(:name) }.sort
    )
    assert_equal %w[popupOrigin provider], parameters.select { |parameter| parameter[:required] }.map { |parameter| parameter[:name] }.sort
    assert parameters.all? { |parameter| parameter.dig(:schema, :type) == "string" }
  end

  def test_untrusted_redirect_inputs_return_specific_safe_completion_errors
    auth = build_generic_auth
    {
      callbackURL: "invalid_callback_url",
      errorCallbackURL: "invalid_error_callback_url",
      newUserCallbackURL: "invalid_new_user_callback_url"
    }.each do |field, code|
      status, headers, body = popup_start(auth, field => "https://evil.example/path")

      assert_equal 200, status
      assert_equal code, completion_data(body).dig("error", "code")
      refute headers.key?("location")
      refute BetterAuth::Cookies.split_set_cookie_header(headers["set-cookie"]).any? { |line| line.start_with?("#{popup_cookie_name(auth)}=") }
      refute_includes body.join, "https://evil.example/path"
    end
  end

  def test_untrusted_or_non_absolute_popup_origin_is_forbidden_without_completion_or_cookie
    auth = build_generic_auth
    [
      "https://evil.example",
      "/relative",
      "http://user:password@localhost:3000",
      "http://localhost:3000/path",
      "http://localhost:3000/?query=value",
      "http://localhost:3000/#fragment",
      "ftp://localhost:3000",
      "https://*.example.com"
    ].each do |origin|
      status, headers, body = popup_start(auth, popupOrigin: origin)

      assert_equal 403, status
      assert_equal "application/json", headers.fetch("content-type")
      assert_equal "INVALID_ORIGIN", JSON.parse(body.join).fetch("code")
      refute_includes body.join, "better-auth-oauth-popup"
      refute BetterAuth::Cookies.split_set_cookie_header(headers["set-cookie"]).any? { |line| line.start_with?("#{popup_cookie_name(auth)}=") }
    end
  end

  def test_popup_origin_root_slash_is_canonicalized_before_post_message
    auth = build_generic_auth
    status, _headers, body = popup_start(auth, provider: "missing", popupOrigin: "#{POPUP_ORIGIN}/")

    assert_equal 200, status
    assert_equal POPUP_ORIGIN, completion_data(body).fetch("targetOrigin")
  end

  def test_malformed_additional_data_is_treated_as_empty
    auth = build_generic_auth
    status, headers, = popup_start(auth, additionalData: "{not-json")

    assert_equal 302, status
    assert authorization_params(headers)["state"]
  end

  def test_tampered_marker_does_not_transform_callback
    auth = build_generic_auth
    _start_status, start_headers, = popup_start(auth, callbackURL: "/dashboard")
    state = authorization_params(start_headers).fetch("state")
    request_cookie = cookie_header(start_headers.fetch("set-cookie"))
    request_cookie = request_cookie.sub(/(#{Regexp.escape(popup_cookie_name(auth))}=[^;]+)./, "\\1x")

    status, headers, = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      headers: {"cookie" => request_cookie},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/dashboard", headers.fetch("location")
  end

  def test_valid_but_malformed_marker_is_cleared_without_transforming_callback
    auth = build_generic_auth
    _start_status, start_headers, = popup_start(auth, callbackURL: "/dashboard")
    state = authorization_params(start_headers).fetch("state")
    request_cookie = cookie_header(start_headers.fetch("set-cookie"))
    payload = "not-json"
    signature = BetterAuth::Crypto.hmac_signature(payload, SECRET, encoding: :base64url)
    encoded = URI.encode_uri_component("#{payload}.#{signature}")
    request_cookie = request_cookie.sub(
      /#{Regexp.escape(popup_cookie_name(auth))}=[^;]*/,
      "#{popup_cookie_name(auth)}=#{encoded}"
    )

    status, headers, = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      headers: {"cookie" => request_cookie},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/dashboard", headers.fetch("location")
    assert marker_expired?(auth, headers.fetch("set-cookie"))
  end

  def test_unrecognized_callback_clears_marker_and_cleared_marker_cannot_replay
    auth = build_generic_auth
    _start_status, start_headers, = popup_start(auth)
    marker_request = cookie_header(start_headers.fetch("set-cookie"))
    ctx = callback_hook_context(auth, cookie: marker_request, location: "/dashboard")

    assert_nil BetterAuth::Plugins.oauth_popup_after_callback(ctx)
    assert_equal "/dashboard", ctx.response_headers.fetch("location")
    assert marker_expired?(auth, ctx.response_headers.fetch("set-cookie"))

    cleared_cookie = cookie_header(ctx.response_headers.fetch("set-cookie"))
    replay = callback_hook_context(auth, cookie: cleared_cookie, location: "/error?error=access_denied")

    assert_nil BetterAuth::Plugins.oauth_popup_after_callback(replay)
    assert_equal "/error?error=access_denied", replay.response_headers.fetch("location")
    refute replay.response_headers.key?("content-security-policy")
    refute replay.response_headers.key?("set-cookie")
  end

  def test_secure_cookie_configuration_uses_secure_popup_marker_name
    auth = build_generic_auth(base_url: "https://auth.example.com", trusted_origins: ["https://app.example.com"], secure: true)
    status, headers, = popup_start(auth, popupOrigin: "https://app.example.com", scheme: "https", host: "auth.example.com")

    assert_equal 302, status
    assert BetterAuth::Cookies.split_set_cookie_header(headers.fetch("set-cookie")).any? { |line| line.start_with?("__Secure-better-auth.oauth_popup=") }
  end

  def test_missing_bearer_warns_only_once_without_becoming_a_dependency
    warnings = []
    auth = build_generic_auth(bearer: false, logger: ->(level, message, *) { warnings << [level, message] })

    2.times do
      _start_status, start_headers, = popup_start(auth)
      state = authorization_params(start_headers).fetch("state")
      popup_callback(auth, start_headers, state: state)
    end

    matching = warnings.select { |level, message| level == :warn && message.include?("bearer") }
    assert_equal 1, matching.length
  end

  def test_generic_oauth_popup_uses_database_and_cookie_state_strategies
    [nil, "cookie"].each do |strategy|
      auth = build_generic_auth(state_strategy: strategy)
      _start_status, start_headers, = popup_start(auth, callbackURL: "/dashboard")
      state = authorization_params(start_headers).fetch("state")
      cookie_name = auth.context.create_auth_cookie(strategy ? "oauth_state" : "state").name

      assert cookie_line(start_headers, cookie_name)
      assert_equal 128, stored_generic_verifier(auth, start_headers, state, strategy).length

      status, headers, body = popup_callback(auth, start_headers, state: state)

      assert_equal 200, status
      refute headers.key?("location")
      assert_equal "/dashboard", completion_data(body).fetch("redirectTo")
    end
  end

  private

  def build_generic_auth(state_strategy: nil, bearer: true, logger: nil, base_url: BASE_URL, trusted_origins: [POPUP_ORIGIN], secure: false, provider_overrides: {})
    plugins = [
      BetterAuth::Plugins.generic_oauth(
        config: [
          {
            provider_id: "custom",
            authorization_url: "https://provider.example.com/authorize",
            token_url: "https://provider.example.com/token",
            client_id: "client-id",
            client_secret: "client-secret",
            scopes: ["profile", "email"],
            pkce: true,
            get_token: ->(code:, **data) {
              raise "unexpected code" unless code == "oauth-code"
              raise "missing verifier" if data[:codeVerifier].to_s.empty?

              {accessToken: "access-token", refreshToken: "refresh-token"}
            },
            get_user_info: ->(_tokens) {
              {id: "popup-sub", email: "popup@example.com", name: "Popup User", emailVerified: true}
            }
          }.merge(provider_overrides)
        ]
      ),
      BetterAuth::Plugins.oauth_popup
    ]
    plugins << BetterAuth::Plugins.bearer if bearer
    account = {}
    account[:store_state_strategy] = state_strategy if state_strategy

    BetterAuth.auth(
      base_url: base_url,
      secret: SECRET,
      database: :memory,
      trusted_origins: trusted_origins,
      account: account,
      session: {cookie_cache: {enabled: true}},
      advanced: {use_secure_cookies: secure},
      logger: logger,
      plugins: plugins
    )
  end

  def build_builtin_auth(last_login_method: false, plugin_order: :popup_first, state_strategy: nil, validate_authorization_code: nil, &authorization_url)
    plugins = [BetterAuth::Plugins.oauth_popup, BetterAuth::Plugins.bearer]
    if last_login_method
      last_login = BetterAuth::Plugins.last_login_method
      plugins = if plugin_order == :popup_first
        [BetterAuth::Plugins.oauth_popup, last_login, BetterAuth::Plugins.bearer]
      else
        [last_login, BetterAuth::Plugins.oauth_popup, BetterAuth::Plugins.bearer]
      end
    end

    BetterAuth.auth(
      base_url: BASE_URL,
      secret: SECRET,
      database: :memory,
      trusted_origins: [POPUP_ORIGIN],
      account: state_strategy ? {store_state_strategy: state_strategy} : {},
      session: {cookie_cache: {enabled: true}},
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: authorization_url,
          validate_authorization_code: validate_authorization_code || ->(_data) { {accessToken: "access-token"} },
          get_user_info: ->(_tokens) {
            {user: {id: "github-sub", email: "github@example.com", name: "GitHub User", emailVerified: true}}
          }
        }
      },
      plugins: plugins
    )
  end

  def popup_start(auth, overrides = {})
    defaults = {provider: "custom", popupOrigin: POPUP_ORIGIN, popupNonce: "nonce-1"}
    scheme = overrides.delete(:scheme) || URI.parse(auth.context.canonical_base_url).scheme
    host = overrides.delete(:host) || URI.parse(auth.context.canonical_base_url).host
    query = URI.encode_www_form(defaults.merge(overrides))
    auth.call(rack_env("GET", "/api/auth/oauth-popup/start?#{query}", scheme: scheme, host: host))
  end

  def popup_callback(auth, start_headers, state:)
    auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      headers: {"cookie" => cookie_header(start_headers.fetch("set-cookie"))},
      as_response: true
    )
  end

  def rack_env(method, target, scheme: "http", host: "localhost", cookie: nil)
    uri = URI.parse(target)
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => uri.path,
      "QUERY_STRING" => uri.query.to_s,
      "SERVER_NAME" => host,
      "SERVER_PORT" => (scheme == "https") ? "443" : "3000",
      "rack.url_scheme" => scheme,
      "rack.input" => StringIO.new("")
    }
    env["HTTP_COOKIE"] = cookie if cookie
    env
  end

  def authorization_params(headers)
    Rack::Utils.parse_query(URI.parse(headers.fetch("location")).query)
  end

  def cookie_header(set_cookie)
    BetterAuth::Cookies.split_set_cookie_header(set_cookie).map { |line| line.split(";", 2).first }.join("; ")
  end

  def cookie_header_without(cookie, name)
    cookie.split("; ").reject { |entry| entry.start_with?("#{name}=") }.join("; ")
  end

  def cookie_line(headers, name)
    BetterAuth::Cookies.split_set_cookie_header(headers["set-cookie"]).find { |line| line.start_with?("#{name}=") }
  end

  def popup_cookie_name(auth)
    auth.context.create_auth_cookie("oauth_popup").name
  end

  def signed_cookie_payload(line, name)
    value = BetterAuth::Cookies.parse_set_cookie(line).fetch(:value)
    encoded = URI.decode_uri_component(value)
    payload, signature = encoded.rpartition(".").values_at(0, 2)
    return nil unless BetterAuth::Crypto.verify_hmac_signature(payload, signature, SECRET, encoding: :base64url)

    JSON.parse(payload)
  end

  def completion_data(body)
    source = body.respond_to?(:join) ? body.join : body.to_s
    encoded = source.match(%r{<script type="application/json" id="better-auth-oauth-popup">(.*?)</script>}m)&.captures&.first
    raise "completion data missing" unless encoded

    JSON.parse(encoded)
  end

  def stored_generic_verifier(auth, start_headers, state, strategy)
    if strategy
      name = auth.context.create_auth_cookie("oauth_state").name
      encrypted = BetterAuth::Cookies.parse_cookies(cookie_header(start_headers.fetch("set-cookie"))).fetch(name)
      JSON.parse(BetterAuth::Crypto.symmetric_decrypt(key: auth.context.secret_config, data: encrypted)).fetch("codeVerifier")
    else
      auth.context.internal_adapter.adapter.find_many(model: "verification")
        .map { |record| JSON.parse(record.fetch("value")) }
        .find { |data| data["expiresAt"] && auth.context.internal_adapter.find_verification_value(state) }
        .fetch("codeVerifier")
    end
  end

  def stored_oauth_state(auth, headers, state, strategy)
    if strategy == "cookie"
      name = auth.context.create_auth_cookie("oauth_state").name
      encrypted = BetterAuth::Cookies.parse_cookies(cookie_header(headers.fetch("set-cookie"))).fetch(name)
      JSON.parse(BetterAuth::Crypto.symmetric_decrypt(key: auth.context.secret_config, data: encrypted))
    else
      JSON.parse(auth.context.internal_adapter.find_verification_value(state).fetch("value"))
    end
  end

  def assert_state_cookie_expired(auth, headers, strategy)
    name = auth.context.create_auth_cookie((strategy == "cookie") ? "oauth_state" : "state").name
    line = BetterAuth::Cookies.split_set_cookie_header(headers.fetch("set-cookie")).reverse.find { |cookie| cookie.start_with?("#{name}=") }

    assert line
    assert_includes line, "Max-Age=0"
  end

  def callback_hook_context(auth, cookie:, location:)
    BetterAuth::Endpoint::Context.new(
      path: "/callback/custom",
      method: "GET",
      query: {},
      body: {},
      params: {id: "custom"},
      headers: {"cookie" => cookie},
      context: auth.context
    ).tap { |ctx| ctx.response_headers["location"] = location }
  end

  def marker_expired?(auth, set_cookie)
    BetterAuth::Cookies.split_set_cookie_header(set_cookie).any? do |line|
      line.start_with?("#{popup_cookie_name(auth)}=") && line.match?(/Max-Age=0/i)
    end
  end

  def cookie_expired?(set_cookie, name)
    BetterAuth::Cookies.split_set_cookie_header(set_cookie).any? do |line|
      line.start_with?("#{name}=") && line.match?(/Max-Age=0/i)
    end
  end
end
