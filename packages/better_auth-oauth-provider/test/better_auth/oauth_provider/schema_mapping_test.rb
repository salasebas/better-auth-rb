# frozen_string_literal: true

require_relative "../../test_helper"

class BetterAuthOAuthProviderSchemaMappingTest < Minitest::Test
  SECRET = "oauth-provider-schema-secret-with-enough-entropy"

  def test_custom_schema_maps_all_models_and_fields_through_migration_projection
    plugin = BetterAuth::Plugins.oauth_provider(
      schema: {
        oauth_client: {
          model_name: "custom_oauth_clients",
          fields: {client_id: "provider_client_id"}
        },
        oauthRefreshToken: {
          modelName: "custom_oauth_refresh_tokens",
          fields: {sessionId: "provider_session_id"}
        },
        oauth_access_token: {
          model_name: "custom_oauth_access_tokens",
          fields: {expires_at: "access_token_expiry"}
        },
        oauthConsent: {
          modelName: "custom_oauth_consents",
          fields: {clientId: "consent_client_id"}
        }
      }
    )
    options = schema_options(plugin)
    tables = BetterAuth::Schema.auth_tables(options)
    migration_tables = BetterAuth::Schema.migration_tables(options)
    base_tables = BetterAuth::Schema.auth_tables(schema_options(BetterAuth::Plugins.oauth_provider))
    mappings = {
      "oauthClient" => ["custom_oauth_clients", "clientId", "provider_client_id"],
      "oauthRefreshToken" => ["custom_oauth_refresh_tokens", "sessionId", "provider_session_id"],
      "oauthAccessToken" => ["custom_oauth_access_tokens", "expiresAt", "access_token_expiry"],
      "oauthConsent" => ["custom_oauth_consents", "clientId", "consent_client_id"]
    }
    default_table_names = {
      "oauthClient" => "oauth_clients",
      "oauthRefreshToken" => "oauth_refresh_tokens",
      "oauthAccessToken" => "oauth_access_tokens",
      "oauthConsent" => "oauth_consents"
    }

    assert_equal mappings.keys.sort, tables.keys.grep(/^oauth/).sort

    mappings.each do |logical_model, (table_name, logical_field, column_name)|
      table = tables.fetch(logical_model)
      base_table = base_tables.fetch(logical_model)
      field = table.fetch(:fields).fetch(logical_field)
      base_field = base_table.fetch(:fields).fetch(logical_field)

      assert_equal base_table.fetch(:fields).keys, table.fetch(:fields).keys
      assert_equal base_field.except(:field_name), field.except(:field_name)
      assert_equal default_table_names.fetch(logical_model), base_table.fetch(:model_name)
      assert_equal BetterAuth::Schema.physical_name(logical_field), base_field.fetch(:field_name)
      assert_equal table_name, table.fetch(:model_name)
      assert_equal column_name, field.fetch(:field_name)
      assert_equal table_name, BetterAuth::Schema.storage_model_name(options, logical_model)
      assert_equal column_name, BetterAuth::Schema.storage_field_name(options, logical_model, logical_field)
      assert_includes migration_tables.fetch(table_name).fetch(:fields), column_name
    end
  end

  def test_custom_schema_ignores_unknown_empty_and_non_string_mappings_without_instance_bleed
    customized = BetterAuth::Plugins.oauth_provider(
      schema: {
        oauth_client: {
          model_name: "",
          fields: {
            client_secret: {field_name: "not_a_string_mapping"},
            disabled: "",
            name: nil,
            unknown_field: "ignored_column"
          }
        },
        unknown_model: {
          model_name: "ignored_table",
          fields: {id: "ignored_id"}
        }
      }
    )
    customized_tables = BetterAuth::Schema.auth_tables(schema_options(customized))
    default_tables = BetterAuth::Schema.auth_tables(schema_options(BetterAuth::Plugins.oauth_provider))
    client = customized_tables.fetch("oauthClient")

    refute customized_tables.key?("unknownModel")
    refute client.fetch(:fields).key?("unknownField")
    assert_equal "oauth_clients", client.fetch(:model_name)
    assert_equal "client_secret", client.dig(:fields, "clientSecret", :field_name)
    assert_equal "disabled", client.dig(:fields, "disabled", :field_name)
    assert_equal "name", client.dig(:fields, "name", :field_name)
    assert_equal false, client.dig(:fields, "clientSecret", :required)
    assert_equal "oauth_clients", default_tables.fetch("oauthClient").fetch(:model_name)
    assert_equal "client_id", default_tables.dig("oauthClient", :fields, "clientId", :field_name)
  end

  private

  def schema_options(plugin)
    BetterAuth::Configuration.new(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: :memory,
      plugins: [plugin]
    )
  end
end
