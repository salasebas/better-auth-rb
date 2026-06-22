# frozen_string_literal: true

require_relative "../../test_helper"

load File.expand_path("../../../../better_auth-api-key/lib/better_auth/api_key/schema.rb", __dir__)
load File.expand_path("../../../../better_auth-passkey/lib/better_auth/passkey/schema.rb", __dir__)
load File.expand_path("../../../../better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider/schema.rb", __dir__)
load File.expand_path("../../../../better_auth-sso/lib/better_auth/sso/routes/schemas.rb", __dir__)
load File.expand_path("../../../../better_auth-stripe/lib/better_auth/stripe/schema.rb", __dir__)

class BetterAuthPluginsSchemaPersistenceMatrixTest < Minitest::Test
  SECRET = "plugin-schema-secret-with-enough-entropy"

  def test_official_schema_plugins_render_for_supported_sql_dialects
    config = schema_config
    expected = expected_schema_entries

    %i[sqlite postgres mysql mssql].each do |dialect|
      sql = BetterAuth::Schema::SQL.create_statements(config, dialect: dialect).join("\n")

      expected.each do |entry|
        assert_includes sql, entry.fetch(:physical_table), "expected #{dialect} SQL to include #{entry.fetch(:physical_table)}"
        assert_includes sql, entry.fetch(:physical_column), "expected #{dialect} SQL to include #{entry.fetch(:physical_column)}"
      end
    end
  end

  def test_official_schema_plugins_execute_combined_schema_on_sqlite
    require "sqlite3"

    db = SQLite3::Database.new(":memory:")
    statements = BetterAuth::Schema::SQL.create_statements(schema_config, dialect: :sqlite)
    statements.each { |statement| db.execute(statement) }
    tables = db.execute("SELECT name FROM sqlite_master WHERE type = 'table'").flatten.sort

    assert_equal %w[
      accounts
      api_keys
      device_codes
      invitations
      jwks
      members
      oauth_access_tokens
      oauth_clients
      oauth_consents
      oauth_refresh_tokens
      organization_roles
      organizations
      passkeys
      rate_limits
      scim_providers
      sessions
      sso_providers
      subscriptions
      team_members
      teams
      two_factors
      users
      verifications
      wallet_addresses
    ], tables

    created = create_table_names(statements.join("\n"), :sqlite)
    duplicates = created.group_by(&:itself).select { |_name, names| names.length > 1 }
    assert_empty duplicates
  rescue LoadError
    skip "sqlite3 gem is not installed"
  end

  def test_official_schema_plugins_project_logical_and_physical_fields
    tables = BetterAuth::Schema.auth_tables(schema_config)
    migration_tables = BetterAuth::Schema.migration_tables(schema_config)

    expected_schema_entries.each do |entry|
      logical_fields = tables.fetch(entry.fetch(:logical_table)).fetch(:fields)
      physical_fields = migration_tables.fetch(entry.fetch(:physical_table)).fetch(:fields)

      assert_includes logical_fields, entry.fetch(:logical_field), "expected logical #{entry.fetch(:logical_table)}.#{entry.fetch(:logical_field)}"
      assert_includes physical_fields, entry.fetch(:physical_column), "expected physical #{entry.fetch(:physical_table)}.#{entry.fetch(:physical_column)}"
    end

    user_fields = tables.fetch("user").fetch(:fields)
    assert_includes user_fields, "username"
    assert_includes user_fields, "displayUsername"
    assert_includes user_fields, "isAnonymous"
    assert_includes user_fields, "phoneNumber"
    assert_includes user_fields, "phoneNumberVerified"
    assert_includes user_fields, "twoFactorEnabled"
    assert_includes user_fields, "lastLoginMethod"
    assert_includes user_fields, "plan"

    session_fields = tables.fetch("session").fetch(:fields)
    assert_includes session_fields, "activeOrganizationId"
    assert_includes session_fields, "activeTeamId"
    assert_includes session_fields, "traceId"

    assert_includes tables.fetch("twoFactor").fetch(:fields), "backupCodes"
    assert_includes tables.fetch("deviceCode").fetch(:fields), "pollingInterval"
    assert_includes tables.fetch("walletAddress").fetch(:fields), "address"
    assert_includes tables.fetch("jwks").fetch(:fields), "privateKey"
    assert_includes tables.fetch("organizationRole").fetch(:fields), "permission"
  end

  private

  def schema_config
    BetterAuth::Configuration.new(
      secret: SECRET,
      database: :memory,
      rate_limit: {storage: "database"},
      plugins: [
        BetterAuth::Plugins.username,
        BetterAuth::Plugins.admin,
        BetterAuth::Plugins.anonymous,
        BetterAuth::Plugins.phone_number(send_otp: ->(_data, _ctx = nil) {}),
        BetterAuth::Plugins.two_factor,
        BetterAuth::Plugins.organization(teams: {enabled: true}, dynamic_access_control: {enabled: true}),
        BetterAuth::Plugins.jwt,
        BetterAuth::Plugins.device_authorization,
        BetterAuth::Plugins.siwe,
        BetterAuth::Plugins.last_login_method(store_in_database: true),
        BetterAuth::Plugins.additional_fields(
          user: {plan: {type: "string", required: false}},
          session: {traceId: {type: "string", required: false}}
        ),
        BetterAuth::Plugins.custom_session(->(session, _ctx) { session }),
        api_key_schema_plugin,
        passkey_schema_plugin,
        oauth_provider_schema_plugin,
        scim_schema_plugin,
        sso_schema_plugin,
        stripe_schema_plugin
      ]
    )
  end

  def api_key_schema_plugin
    BetterAuth::Plugin.new(
      id: "api-key",
      schema: BetterAuth::APIKey::SchemaDefinition.schema(rate_limit: {time_window: 86_400_000, max_requests: 10})
    )
  end

  def passkey_schema_plugin
    BetterAuth::Plugin.new(
      id: "passkey",
      schema: BetterAuth::Passkey::Schema.passkey_schema
    )
  end

  def oauth_provider_schema_plugin
    BetterAuth::Plugin.new(
      id: "oauth-provider",
      schema: BetterAuth::Plugins.oauth_provider_schema
    )
  end

  def scim_schema_plugin
    BetterAuth::Plugin.new(
      id: "scim",
      schema: {
        scimProvider: {
          model_name: "scim_providers",
          fields: {
            providerId: {type: "string", required: true, unique: true},
            scimToken: {type: "string", required: true, unique: true},
            organizationId: {type: "string", required: false},
            userId: {type: "string", required: false}
          }
        }
      }
    )
  end

  def sso_schema_plugin
    BetterAuth::Plugin.new(
      id: "sso",
      schema: BetterAuth::SSO::Routes::Schemas.plugin_schema(domain_verification: {enabled: true})
    )
  end

  def stripe_schema_plugin
    BetterAuth::Plugin.new(
      id: "stripe",
      schema: BetterAuth::Stripe::Schema.schema(subscription: {enabled: true, plans: []}, organization: {enabled: true})
    )
  end

  def expected_schema_entries
    [
      {logical_table: "user", logical_field: "role", physical_table: "users", physical_column: "role"},
      {logical_table: "session", logical_field: "impersonatedBy", physical_table: "sessions", physical_column: "impersonated_by"},
      {logical_table: "user", logical_field: "plan", physical_table: "users", physical_column: "plan"},
      {logical_table: "session", logical_field: "traceId", physical_table: "sessions", physical_column: "trace_id"},
      {logical_table: "user", logical_field: "username", physical_table: "users", physical_column: "username"},
      {logical_table: "user", logical_field: "isAnonymous", physical_table: "users", physical_column: "is_anonymous"},
      {logical_table: "user", logical_field: "phoneNumber", physical_table: "users", physical_column: "phone_number"},
      {logical_table: "user", logical_field: "twoFactorEnabled", physical_table: "users", physical_column: "two_factor_enabled"},
      {logical_table: "organization", logical_field: "slug", physical_table: "organizations", physical_column: "slug"},
      {logical_table: "team", logical_field: "organizationId", physical_table: "teams", physical_column: "organization_id"},
      {logical_table: "organizationRole", logical_field: "permission", physical_table: "organization_roles", physical_column: "permission"},
      {logical_table: "jwks", logical_field: "privateKey", physical_table: "jwks", physical_column: "private_key"},
      {logical_table: "deviceCode", logical_field: "pollingInterval", physical_table: "device_codes", physical_column: "polling_interval"},
      {logical_table: "walletAddress", logical_field: "address", physical_table: "wallet_addresses", physical_column: "address"},
      {logical_table: "user", logical_field: "lastLoginMethod", physical_table: "users", physical_column: "lastLoginMethod"},
      {logical_table: "apikey", logical_field: "configId", physical_table: "api_keys", physical_column: "config_id"},
      {logical_table: "passkey", logical_field: "credentialId", physical_table: "passkeys", physical_column: "credential_id"},
      {logical_table: "oauthClient", logical_field: "clientId", physical_table: "oauth_clients", physical_column: "client_id"},
      {logical_table: "oauthRefreshToken", logical_field: "clientId", physical_table: "oauth_refresh_tokens", physical_column: "client_id"},
      {logical_table: "scimProvider", logical_field: "scimToken", physical_table: "scim_providers", physical_column: "scim_token"},
      {logical_table: "ssoProvider", logical_field: "domainVerified", physical_table: "sso_providers", physical_column: "domain_verified"},
      {logical_table: "user", logical_field: "stripeCustomerId", physical_table: "users", physical_column: "stripe_customer_id"},
      {logical_table: "organization", logical_field: "stripeCustomerId", physical_table: "organizations", physical_column: "stripe_customer_id"},
      {logical_table: "subscription", logical_field: "stripeSubscriptionId", physical_table: "subscriptions", physical_column: "stripe_subscription_id"}
    ]
  end

  def create_table_names(sql, dialect)
    case dialect
    when :sqlite, :postgres
      sql.scan(/CREATE TABLE IF NOT EXISTS "([^"]+)"/).flatten
    when :mysql
      sql.scan(/CREATE TABLE IF NOT EXISTS `([^`]+)`/).flatten
    when :mssql
      sql.scan(/CREATE TABLE \[([^\]]+)\]/).flatten
    end
  end
end
