# frozen_string_literal: true

require_relative "test_support"

class BetterAuthAPIKeySessionTest < Minitest::Test
  include APIKeyTestSupport

  Context = Struct.new(:headers)

  def test_header_config_selects_enabled_configuration_with_matching_header
    config = BetterAuth::APIKey::Configuration.normalize([
      {config_id: "default", api_key_headers: "x-default-key", enable_session_for_api_keys: false},
      {config_id: "service", api_key_headers: ["x-service-key"], enable_session_for_api_keys: true}
    ])
    ctx = Context.new({"x-service-key" => "service-secret"})

    selected = BetterAuth::APIKey::Session.header_config(ctx, config)

    assert_equal "service", selected.fetch(:config_id)
  end

  def test_header_config_ignores_disabled_session_configuration
    config = BetterAuth::APIKey::Configuration.normalize(
      {api_key_headers: "x-api-key", enable_session_for_api_keys: false}
    )
    ctx = Context.new({"x-api-key" => "secret"})

    assert_nil BetterAuth::APIKey::Session.header_config(ctx, config)
  end

  def test_header_config_skips_empty_key_and_selects_later_configuration
    config = BetterAuth::APIKey::Configuration.normalize([
      {config_id: "empty", api_key_headers: "x-empty-key", enable_session_for_api_keys: true},
      {config_id: "service", api_key_headers: "x-service-key", enable_session_for_api_keys: true}
    ])
    ctx = Context.new({"x-empty-key" => "", "x-service-key" => "service-secret"})

    selected = BetterAuth::APIKey::Session.header_config(ctx, config)

    assert_equal "service", selected.fetch(:config_id)
  end

  def test_session_hook_rejects_non_string_custom_getter_result
    auth = build_api_key_auth(
      enable_session_for_api_keys: true,
      custom_api_key_getter: ->(_ctx) { 123 },
      default_key_length: 12
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.get_session(headers: {"x-api-key" => "ignored"})
    end

    assert_equal "BAD_REQUEST", error.status
    assert_equal BetterAuth::APIKey::ERROR_CODES.fetch("INVALID_API_KEY_GETTER_RETURN_TYPE"), error.message
  end

  def test_session_hook_calls_custom_getter_twice
    getter_calls = 0
    auth = build_api_key_auth(
      enable_session_for_api_keys: true,
      custom_api_key_getter: ->(ctx) {
        getter_calls += 1
        ctx.headers["x-api-key"]
      },
      default_key_length: 12
    )
    created = create_user_api_key(auth, email: "session-getter@example.com")
    getter_calls = 0

    session = auth.api.get_session(headers: {"x-api-key" => created[:key]})

    assert_equal created[:key], session[:session]["token"]
    assert_equal 2, getter_calls
  end

  def test_session_hook_does_not_fall_through_when_custom_getter_changes
    getter_calls = 0
    auth = build_api_key_auth(
      enable_session_for_api_keys: true,
      custom_api_key_getter: ->(ctx) {
        getter_calls += 1
        ctx.headers["x-api-key"] if getter_calls.odd?
      },
      default_key_length: 12
    )
    created = create_user_api_key(auth, email: "session-changing-getter@example.com")
    getter_calls = 0

    assert_raises(NoMethodError) do
      auth.api.get_session(headers: {"x-api-key" => created[:key]})
    end
    assert_equal 2, getter_calls
  end

  def test_session_hook_calls_custom_validator_once
    validator_calls = 0
    auth = build_api_key_auth(
      enable_session_for_api_keys: true,
      custom_api_key_validator: ->(_options) {
        validator_calls += 1
        true
      },
      default_key_length: 12
    )
    created = create_user_api_key(auth, email: "session-validator@example.com")
    validator_calls = 0

    auth.api.get_session(headers: {"x-api-key" => created[:key]})

    assert_equal 1, validator_calls
  end

  def test_session_hook_rejects_key_from_non_selected_configuration
    auth = build_api_key_auth([
      {config_id: "primary", default_key_length: 12, enable_session_for_api_keys: true},
      {config_id: "secondary", default_key_length: 12, enable_session_for_api_keys: true}
    ])
    cookie = sign_up_cookie(auth, email: "session-config@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    created = auth.api.create_api_key(body: {configId: "secondary", userId: user_id})

    assert_raises(BetterAuth::APIError) do
      auth.api.get_session(headers: {"x-api-key" => created[:key]})
    end
  end

  def test_api_key_get_session_short_circuits_post_defer_and_cache_headers
    auth = build_api_key_auth(
      enable_session_for_api_keys: true,
      default_key_length: 12,
      session: {defer_session_refresh: true}
    )
    created = create_user_api_key(auth, email: "session-short-circuit@example.com")
    headers = {"x-api-key" => created[:key]}

    get_session = auth.api.get_session(headers: headers)
    post_session = auth.api.get_session(headers: headers, method: "POST")
    response = auth.api.get_session(headers: headers, as_response: true)

    assert_equal created[:key], get_session[:session]["token"]
    refute get_session.key?(:needsRefresh)
    assert_equal created[:key], post_session[:session]["token"]
    assert_instance_of BetterAuth::Response, response
    assert_equal created[:key], response.json.dig("session", "token")
    refute response.headers.key?("cache-control")
    refute response.headers.key?("pragma")
  end

  def test_api_key_get_session_post_bypasses_defer_requirement
    auth = build_api_key_auth(enable_session_for_api_keys: true, default_key_length: 12)
    created = create_user_api_key(auth, email: "session-post@example.com")

    session = auth.api.get_session(headers: {"x-api-key" => created[:key]}, method: "POST")

    assert_equal created[:key], session[:session]["token"]
  end

  def test_api_key_session_uses_only_request_for_user_agent_and_ip
    auth = build_api_key_auth(
      enable_session_for_api_keys: true,
      default_key_length: 12,
      advanced: {ip_address: {ip_address_headers: ["x-forwarded-for"]}}
    )
    created = create_user_api_key(auth, email: "session-request-metadata@example.com")

    direct_session = auth.api.get_session(headers: {
      "x-api-key" => created[:key],
      "user-agent" => "direct-agent",
      "x-forwarded-for" => "203.0.113.10"
    })

    assert_nil direct_session[:session]["userAgent"]
    assert_nil direct_session[:session]["ipAddress"]

    request = Rack::Request.new(Rack::MockRequest.env_for(
      "http://localhost:3000/api/auth/get-session",
      :method => "GET",
      "HTTP_X_API_KEY" => created[:key],
      "HTTP_USER_AGENT" => "request-agent",
      "HTTP_X_FORWARDED_FOR" => "203.0.113.11",
      "REMOTE_ADDR" => "198.51.100.2"
    ))
    request_session = auth.api.get_session(request: request).json

    assert_equal "request-agent", request_session.dig("session", "userAgent")
    assert_equal "203.0.113.11", request_session.dig("session", "ipAddress")
  end

  private

  def create_user_api_key(auth, email:)
    cookie = sign_up_cookie(auth, email: email)
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    auth.api.create_api_key(body: {userId: user_id})
  end
end
