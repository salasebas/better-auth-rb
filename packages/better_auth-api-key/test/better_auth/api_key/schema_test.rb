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
    assert fields.except(:metadata).values.all? { |attributes| attributes.fetch(:input) == false }
    assert_equal true, fields.fetch(:metadata).fetch(:input)
    assert_equal "string", fields.fetch(:metadata).fetch(:type)
    assert_equal "string", fields.fetch(:permissions).fetch(:type)
  end

  def test_schema_module_maps_logical_names_to_physical_names
    config = BetterAuth::Plugins.api_key_config({rate_limit: {time_window: 1000, max_requests: 10}})
    schema = BetterAuth::APIKey::SchemaDefinition.schema(
      config,
      apikey: {
        model_name: "custom_api_keys",
        fields: {
          config_id: "tenant_key_config",
          name: "api_key_name",
          description: "ignored_description"
        }
      }
    )

    table = schema.fetch(:apikey)
    fields = table.fetch(:fields)
    assert_equal "custom_api_keys", table.fetch(:model_name)
    assert_equal "tenant_key_config", fields.fetch(:configId).fetch(:field_name)
    assert_equal "api_key_name", fields.fetch(:name).fetch(:field_name)
    assert_equal "string", fields.fetch(:configId).fetch(:type)
    assert_equal "default", fields.fetch(:configId).fetch(:default_value)
    assert_equal true, fields.fetch(:configId).fetch(:index)
    refute fields.key?(:description)
  end

  def test_plugin_applies_second_argument_schema_for_single_configuration
    plugin = BetterAuth::Plugins.api_key(
      {schema: {apikey: {model_name: "inline_api_keys", fields: {name: "inline_name"}}}},
      {schema: {apikey: {model_name: "global_api_keys", fields: {name: "global_name"}}}}
    )

    assert_equal "global_api_keys", plugin.schema.dig(:apikey, :model_name)
    assert_equal "global_name", plugin.schema.dig(:apikey, :fields, :name, :field_name)
  end

  def test_array_configuration_schema_is_global_only
    plugin = BetterAuth::Plugins.api_key([
      {config_id: "first", schema: {apikey: {model_name: "inline_api_keys"}}},
      {config_id: "default"}
    ])
    mapped = BetterAuth::Plugins.api_key(
      [{config_id: "first"}, {config_id: "default"}],
      {schema: {apikey: {model_name: "global_api_keys"}}}
    )

    assert_equal "api_keys", plugin.schema.dig(:apikey, :model_name)
    assert_equal "global_api_keys", mapped.schema.dig(:apikey, :model_name)
  end

  def test_multi_and_empty_configuration_schema_use_constant_defaults
    multi = BetterAuth::Plugins.api_key([
      {config_id: "first", rate_limit: {time_window: 111, max_requests: 11}},
      {config_id: "default", rate_limit: {time_window: 222, max_requests: 22}}
    ]).schema.fetch(:apikey).fetch(:fields)
    empty = BetterAuth::Plugins.api_key([]).schema.fetch(:apikey).fetch(:fields)

    [multi, empty].each do |fields|
      assert_equal 86_400_000, fields.dig(:rate_limit_time_window, :default_value)
      assert_equal 10, fields.dig(:rate_limit_max, :default_value)
    end
  end

  def test_single_configuration_schema_uses_its_rate_limit_defaults
    fields = BetterAuth::Plugins.api_key([
      {config_id: "only", rate_limit: {time_window: 0, max_requests: 0}}
    ]).schema.fetch(:apikey).fetch(:fields)

    assert_equal 0, fields.dig(:rate_limit_time_window, :default_value)
    assert_equal 0, fields.dig(:rate_limit_max, :default_value)
  end

  def test_metadata_schema_transforms_json
    transform = BetterAuth::Plugins.api_key.schema.dig(:apikey, :fields, :metadata, :transform)
    encoded = transform.fetch(:input).call({plan: "pro"})

    assert_equal({"plan" => "pro"}, transform.fetch(:output).call(encoded))
    assert_nil transform.fetch(:output).call("")
    assert_equal "null", transform.fetch(:input).call(nil)
  end

  def test_api_key_fields_reach_migration_projection
    config = BetterAuth::Configuration.new(
      secret: "api-key-schema-secret-with-enough-entropy",
      base_url: "http://localhost:3000",
      database: :memory,
      plugins: [BetterAuth::Plugins.api_key]
    )
    fields = BetterAuth::Schema.migration_tables(config).fetch("api_keys").fetch(:fields)

    assert_includes fields, "config_id"
    assert_includes fields, "reference_id"
    assert_equal true, fields.fetch("key").fetch(:index)
  end

  def test_custom_name_mappings_reach_migration_projection
    config = BetterAuth::Configuration.new(
      secret: "api-key-custom-schema-secret-with-enough-entropy",
      base_url: "http://localhost:3000",
      database: :memory,
      plugins: [
        BetterAuth::Plugins.api_key(
          {},
          {schema: {apikey: {model_name: "custom_api_keys", fields: {config_id: "tenant_key_config"}}}}
        )
      ]
    )

    table = BetterAuth::Schema.migration_tables(config).fetch("custom_api_keys")
    field = table.fetch(:fields).fetch("tenant_key_config")

    assert_equal "configId", field.fetch(:logical_name)
    assert_equal "string", field.fetch(:type)
    assert_equal "default", field.fetch(:default_value)
    assert_equal true, field.fetch(:index)
  end
end
