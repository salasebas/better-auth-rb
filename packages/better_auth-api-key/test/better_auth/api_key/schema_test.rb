# frozen_string_literal: true

require_relative "test_support"

class BetterAuthAPIKeySchemaTest < Minitest::Test
  def test_schema_matches_upstream_reference_id_shape
    schema = BetterAuth::Plugins.api_key(rate_limit: {time_window: 1234, max_requests: 99}).schema
    table = schema.fetch(:apikey)
    fields = table.fetch(:fields)

    assert_equal "api_keys", table.fetch(:model_name)
    assert_equal %i[
      config_id
      created_at
      enabled
      expires_at
      key
      last_refill_at
      last_request
      metadata
      name
      permissions
      prefix
      rate_limit_enabled
      rate_limit_max
      rate_limit_time_window
      reference_id
      refill_amount
      refill_interval
      remaining
      request_count
      start
      updated_at
    ].sort, fields.keys.sort
    assert fields.key?(:config_id)
    assert fields.key?(:reference_id)
    refute fields.key?(:user_id)
    assert_equal 1234, fields.fetch(:rate_limit_time_window).fetch(:default_value)
    assert_equal 99, fields.fetch(:rate_limit_max).fetch(:default_value)
    assert_equal true, fields.fetch(:config_id).fetch(:required)
    assert_equal "default", fields.fetch(:config_id).fetch(:default_value)
    assert_equal true, fields.fetch(:key).fetch(:index)
    assert_equal true, fields.fetch(:reference_id).fetch(:index)
    assert_equal "string", fields.fetch(:metadata).fetch(:type)
    assert_equal "string", fields.fetch(:permissions).fetch(:type)
  end

  def test_schema_module_applies_custom_schema_merge
    config = BetterAuth::Plugins.api_key_config({rate_limit: {time_window: 1000, max_requests: 10}})
    schema = BetterAuth::APIKey::SchemaDefinition.schema(config, apikey: {fields: {description: {type: "string"}}})

    assert_equal({type: "string"}, schema.fetch(:apikey).fetch(:fields).fetch(:description))
    assert schema.fetch(:apikey).fetch(:fields).key?(:referenceId)
  end

  def test_schema_module_allows_custom_schema_to_override_field_attributes
    config = BetterAuth::Plugins.api_key_config({rate_limit: {time_window: 1000, max_requests: 10}})
    schema = BetterAuth::APIKey::SchemaDefinition.schema(
      config,
      apikey: {fields: {name: {type: "string", required: true}}}
    )

    assert_equal true, schema.fetch(:apikey).fetch(:fields).fetch(:name).fetch(:required)
    assert_equal "string", schema.fetch(:apikey).fetch(:fields).fetch(:name).fetch(:type)
  end
end
