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
end
