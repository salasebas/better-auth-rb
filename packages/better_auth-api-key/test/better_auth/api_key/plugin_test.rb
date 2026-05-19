# frozen_string_literal: true

require_relative "test_support"

class BetterAuthAPIKeyPluginTest < Minitest::Test
  include APIKeyTestSupport

  def test_public_plugin_metadata_matches_upstream_entrypoint
    plugin = BetterAuth::Plugins.api_key

    assert_equal "api-key", plugin.id
    assert_equal BetterAuth::APIKey::VERSION, plugin.version
    assert_equal BetterAuth::APIKey::ERROR_CODES, plugin.error_codes
    assert_equal BetterAuth::APIKey::ERROR_CODES, BetterAuth::Plugins::API_KEY_ERROR_CODES
    assert_equal "apikey", BetterAuth::Plugins::API_KEY_TABLE_NAME
  end

  def test_plugin_factory_builds_same_public_contract
    plugin = BetterAuth::APIKey::PluginFactory.build(default_key_length: 12)

    assert_equal "api-key", plugin.id
    assert_equal BetterAuth::APIKey::VERSION, plugin.version
    assert_equal BetterAuth::APIKey::ERROR_CODES, plugin.error_codes
    assert_equal %i[
      create_api_key
      verify_api_key
      get_api_key
      update_api_key
      delete_api_key
      list_api_keys
      delete_all_expired_api_keys
    ].sort, plugin.endpoints.keys.sort
    assert_equal 12, plugin.options[:default_key_length]
  end

  def test_visible_endpoints_have_complete_open_api_metadata
    missing = BetterAuth::Plugins.api_key.endpoints.filter_map do |key, endpoint|
      next unless endpoint.path
      next if endpoint.metadata[:hide] || endpoint.metadata[:SERVER_ONLY] || endpoint.metadata[:server_only]

      "#{BetterAuth::Plugins.api_key.id}.#{key}" unless rich_openapi?(endpoint)
    end

    assert_empty missing
  end

  def test_api_key_open_api_request_fields_match_upstream_contract
    endpoints = BetterAuth::Plugins.api_key.endpoints

    create_properties = request_body_properties(endpoints.fetch(:create_api_key))
    assert_equal %i[
      configId
      expiresIn
      metadata
      name
      organizationId
      permissions
      prefix
      rateLimitEnabled
      rateLimitMax
      rateLimitTimeWindow
      refillAmount
      refillInterval
      remaining
      userId
    ].sort, create_properties.keys.sort

    update_schema = request_body_schema(endpoints.fetch(:update_api_key))
    assert_includes update_schema[:required], "keyId"
    assert_includes update_schema[:properties].keys, :enabled

    delete_schema = request_body_schema(endpoints.fetch(:delete_api_key))
    assert_equal ["keyId"], delete_schema[:required]

    verify_schema = request_body_schema(endpoints.fetch(:verify_api_key))
    assert_equal ["key"], verify_schema[:required]

    get_params = endpoints.fetch(:get_api_key).metadata.dig(:openapi, :parameters)
    assert get_params.any? { |parameter| parameter[:name] == "id" && parameter[:required] == true }
  end

  def test_default_key_hasher_matches_sha256_base64url_contract
    assert_equal BetterAuth::Crypto.sha256("api-key-value", encoding: :base64url),
      BetterAuth::Plugins.default_api_key_hasher("api-key-value")
  end

  def test_api_key_session_hook_uses_configured_header
    auth = build_api_key_auth(api_key_headers: ["x-custom-api-key"], enable_session_for_api_keys: true, default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "plugin-session-key@example.com")
    created = auth.api.create_api_key(headers: {"cookie" => cookie}, body: {})

    assert_nil auth.api.get_session(headers: {"x-api-key" => created[:key]})

    session = auth.api.get_session(headers: {"x-custom-api-key" => created[:key]})
    assert_equal "plugin-session-key@example.com", session[:user]["email"]
  end

  private

  def rich_openapi?(endpoint)
    openapi = endpoint.metadata[:openapi]
    return false unless openapi.is_a?(Hash)
    return false if openapi[:operationId].to_s.empty?
    return false if endpoint.methods.any? { |method| openapi[:description].to_s == "#{method} #{endpoint.path}" }
    return false unless openapi[:responses].is_a?(Hash) && openapi[:responses].any?
    return false if request_body_method?(endpoint) && !meaningful_schema?(openapi.dig(:requestBody, :content, "application/json", :schema))

    true
  end

  def request_body_method?(endpoint)
    endpoint.methods.any? { |method| %w[POST PUT PATCH].include?(method) }
  end

  def meaningful_schema?(schema)
    return false unless schema.is_a?(Hash)
    return false if schema[:additionalProperties] == true && schema[:properties] == {}

    schema[:$ref] || schema[:items] || schema.key?(:properties) || schema[:additionalProperties]
  end

  def request_body_schema(endpoint)
    endpoint.metadata.dig(:openapi, :requestBody, :content, "application/json", :schema)
  end

  def request_body_properties(endpoint)
    request_body_schema(endpoint).fetch(:properties)
  end
end
