# frozen_string_literal: true

require_relative "test_support"

class BetterAuthAPIKeyConfigurationTest < Minitest::Test
  def test_single_configuration_applies_upstream_defaults
    config = BetterAuth::APIKey::Configuration.normalize({})

    assert_equal "default", config[:config_id]
    assert_equal "x-api-key", config[:api_key_headers]
    assert_equal 64, config[:default_key_length]
    assert_equal true, config[:rate_limit][:enabled]
    assert_equal 86_400_000, config[:rate_limit][:time_window]
    assert_equal 10, config[:rate_limit][:max_requests]
    assert_equal "user", config[:references]
  end

  def test_multiple_configuration_validation_matches_upstream
    assert_raises(BetterAuth::Error) do
      BetterAuth::APIKey::Configuration.normalize([{config_id: "duplicate"}, {config_id: "duplicate"}])
    end

    assert_raises(BetterAuth::Error) do
      BetterAuth::APIKey::Configuration.normalize([{config_id: "valid"}, {}])
    end

    [false, 0, ""].each do |config_id|
      assert_raises(BetterAuth::Error) do
        BetterAuth::APIKey::Configuration.normalize([{config_id: config_id}])
      end
    end
  end

  def test_empty_configuration_array_is_accepted
    config = BetterAuth::APIKey::Configuration.normalize([])

    assert_empty config[:configurations]
    assert_nil config[:config_id]
  end

  def test_single_configuration_uses_second_argument_schema_when_provided
    inline_schema = {apikey: {model_name: "inline_api_keys"}}
    global_schema = {apikey: {model_name: "global_api_keys"}}

    assert_equal inline_schema, BetterAuth::APIKey::Configuration.normalize({schema: inline_schema})[:schema]
    assert_nil BetterAuth::APIKey::Configuration.normalize({schema: inline_schema}, {})[:schema]
    assert_equal global_schema, BetterAuth::APIKey::Configuration.normalize({schema: inline_schema}, {schema: global_schema})[:schema]
  end

  def test_array_configuration_uses_only_global_schema
    inline_schema = {apikey: {model_name: "inline_api_keys"}}
    global_schema = {apikey: {model_name: "global_api_keys"}}
    configurations = [{config_id: "first", schema: inline_schema}, {config_id: "second"}]

    assert_nil BetterAuth::APIKey::Configuration.normalize(configurations)[:schema]
    assert_equal global_schema, BetterAuth::APIKey::Configuration.normalize(configurations, {schema: global_schema})[:schema]
  end

  def test_falsey_and_nullish_defaults_match_upstream
    config = BetterAuth::APIKey::Configuration.single(
      default_key_length: 0,
      maximum_prefix_length: nil,
      rate_limit: {time_window: false, max_requests: false},
      key_expiration: {max_expires_in: false, min_expires_in: false},
      starting_characters_config: {should_store: nil, characters_length: false}
    )

    assert_equal 64, config[:default_key_length]
    assert_equal 32, config[:maximum_prefix_length]
    assert_equal false, config.dig(:rate_limit, :time_window)
    assert_equal false, config.dig(:rate_limit, :max_requests)
    assert_equal false, config.dig(:key_expiration, :max_expires_in)
    assert_equal false, config.dig(:key_expiration, :min_expires_in)
    assert_equal true, config.dig(:starting_characters_config, :should_store)
    assert_equal false, config.dig(:starting_characters_config, :characters_length)
  end
end
