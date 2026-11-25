# frozen_string_literal: true

require_relative "../../test_helper"

class BetterAuthPasskeySchemaTest < Minitest::Test
  def test_base_schema_matches_upstream_passkey_fields
    fields = BetterAuth::Passkey::Schema.passkey_schema.fetch(:passkey).fetch(:fields)

    assert_equal({type: "string", required: false}, fields.fetch(:name))
    assert_equal({type: "string", required: true}, fields.fetch(:public_key))
    assert_equal({type: "string", references: {model: "user", field: "id"}, required: true, index: true}, fields.fetch(:user_id))
    assert_equal({type: "string", required: true, unique: true}, fields.fetch(:credential_id))
    assert_equal({type: "number", required: true}, fields.fetch(:counter))
    assert_equal({type: "string", required: true}, fields.fetch(:device_type))
    assert_equal({type: "boolean", required: true}, fields.fetch(:backed_up))
    assert_equal({type: "string", required: false}, fields.fetch(:transports))
    assert_equal({type: "date", required: false}, fields.fetch(:created_at))
    assert_equal({type: "string", required: false}, fields.fetch(:aaguid))
  end

  def test_custom_schema_deep_merges_without_dropping_base_metadata
    schema = BetterAuth::Passkey::Schema.passkey_schema(
      passkey: {
        fields: {
          name: {required: true},
          publicKey: {required: false}
        }
      }
    )

    fields = schema.fetch(:passkey).fetch(:fields)

    assert_equal({type: "string", required: true}, fields.fetch(:name))
    assert_equal({type: "string", required: false}, fields.fetch(:public_key))
    assert_equal({type: "number", required: true}, fields.fetch(:counter))
  end

  def test_renamed_counter_keeps_its_sql_type
    plugin = BetterAuth::Plugins.passkey(schema: {passkey: {fields: {counter: "sign_count"}}})
    config = BetterAuth::Configuration.new(
      secret: "passkey-schema-secret-with-enough-entropy",
      database: :memory,
      plugins: [plugin]
    )

    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).join("\n")

    assert_includes sql, '"sign_count" integer NOT NULL'
  end
end
