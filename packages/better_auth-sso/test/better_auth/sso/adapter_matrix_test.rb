# frozen_string_literal: true

require "tempfile"
require_relative "../../test_helper"
require_relative "../../support/sso_test_helpers"

class BetterAuthSSOAdapterMatrixTest < Minitest::Test
  include BetterAuthSSOTestHelpers

  def test_memory_adapter_persists_sso_provider_oidc_callback_saml_state_and_domain_verification
    auth = matrix_auth(database: :memory)

    assert_sso_matrix_round_trip(auth, "memory")
  end

  def test_sqlite_adapter_persists_sso_provider_oidc_callback_saml_state_and_domain_verification
    require "sqlite3"

    Tempfile.create(["better-auth-sso-matrix", ".sqlite3"]) do |file|
      connection = SQLite3::Database.new(file.path)
      connection.results_as_hash = true
      connection.execute("PRAGMA foreign_keys = ON")
      auth = sql_matrix_auth(:sqlite, connection) { |options| BetterAuth::Adapters::SQLite.new(options, connection: connection) }

      assert_sso_matrix_round_trip(auth, "sqlite")
    ensure
      connection&.close
    end
  rescue LoadError
    skip "sqlite3 gem is not installed"
  end

  def test_postgres_adapter_persists_sso_provider_oidc_callback_saml_state_and_domain_verification
    require "pg"

    connection = PG.connect(ENV.fetch("BETTER_AUTH_POSTGRES_URL", "postgres://user:password@localhost:5432/better_auth"))
    reset_postgres_schema(connection)
    auth = sql_matrix_auth(:postgres, connection) { |options| BetterAuth::Adapters::Postgres.new(options, connection: connection) }

    assert_sso_matrix_round_trip(auth, "postgres")
  rescue LoadError
    skip "pg gem is not installed"
  rescue PG::ConnectionBad
    skip "PostgreSQL test service is not available"
  ensure
    connection&.close
  end

  def test_mysql_adapter_persists_sso_provider_oidc_callback_saml_state_and_domain_verification
    require "mysql2"

    connection = mysql_connection
    reset_mysql_schema(connection)
    auth = sql_matrix_auth(:mysql, connection) { |options| BetterAuth::Adapters::MySQL.new(options, connection: connection) }

    assert_sso_matrix_round_trip(auth, "mysql")
  rescue LoadError
    skip "mysql2 gem is not installed"
  rescue Mysql2::Error::ConnectionError
    skip "MySQL test service is not available"
  ensure
    connection&.close
  end

  def test_mssql_adapter_persists_sso_provider_oidc_callback_saml_state_and_domain_verification
    require "sequel"
    require "tiny_tds"

    ensure_mssql_database
    connection = Sequel.connect(ENV.fetch("BETTER_AUTH_MSSQL_URL", "tinytds://sa:Password123!@127.0.0.1:1433/better_auth?timeout=30"))
    reset_mssql_schema(connection)
    auth = sql_matrix_auth(:mssql, connection) { |options| BetterAuth::Adapters::MSSQL.new(options, connection: connection) }

    assert_sso_matrix_round_trip(auth, "mssql")
  rescue LoadError
    skip "sequel or tiny_tds gem is not installed"
  rescue Sequel::DatabaseConnectionError
    skip "MSSQL test service is not available"
  ensure
    connection&.disconnect
  end

  def test_mongodb_adapter_is_exercised_when_real_mongo_package_and_service_are_available
    skip "Set BETTER_AUTH_MONGODB_URL to run the real MongoDB SSO matrix test" unless ENV["BETTER_AUTH_MONGODB_URL"]

    require "mongo"
    require "better_auth/mongodb"

    client = Mongo::Client.new(ENV.fetch("BETTER_AUTH_MONGODB_URL"), database: ENV.fetch("BETTER_AUTH_MONGODB_DATABASE", "better_auth_sso_test"))
    client.database.collections.each(&:drop)
    auth = matrix_auth(database: ->(options) { BetterAuth::Adapters::MongoDB.new(options, database: client.database) })

    assert_sso_matrix_round_trip(auth, "mongodb")
  rescue LoadError
    skip "mongo or better_auth-mongodb gem is not installed"
  rescue => error
    raise unless defined?(Mongo::Error) && error.is_a?(Mongo::Error)

    skip "MongoDB test service is not available"
  ensure
    client&.close
  end

  private

  def matrix_auth(database:)
    build_sso_auth(
      database: database,
      session: {cookie_cache: {enabled: false}},
      plugin_options: matrix_plugin_options
    )
  end

  def sql_matrix_auth(dialect, connection)
    plugin = BetterAuth::Plugins.sso(matrix_plugin_options)
    config = BetterAuth::Configuration.new(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: :memory,
      email_and_password: {enabled: true},
      session: {cookie_cache: {enabled: false}},
      plugins: [plugin]
    )
    create_sql_schema(connection, config, dialect)
    BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: ->(options) { yield options },
      email_and_password: {enabled: true},
      session: {cookie_cache: {enabled: false}},
      plugins: [plugin]
    )
  end

  def matrix_plugin_options
    {
      domain_verification: {
        enabled: true,
        dns_txt_resolver: ->(hostname) {
          identifier = hostname.to_s.split(".", 2).first
          token = @domain_tokens.fetch(identifier)
          ["#{identifier}=#{token}"]
        }
      },
      saml: {
        parse_response: ->(raw_response:, **_data) {
          xml = Base64.decode64(raw_response)
          assertion_id = xml[/\bID=['"]([^'"]+)['"]/, 1]
          {id: assertion_id, email: "matrix-saml-user@example.com", name: "Matrix SAML"}
        }
      }
    }
  end

  def assert_sso_matrix_round_trip(auth, prefix)
    @domain_tokens = {}
    cookie = sign_up_cookie(auth, email: "#{prefix}-owner@example.com")

    oidc_provider = register_oidc_provider(auth, cookie: cookie, provider_id: "#{prefix}-oidc", domain: "#{prefix}-oidc.example.com", oidcConfig: serializable_oidc_config(prefix))
    verify_provider_domain(auth, cookie, oidc_provider)
    assert_equal "#{prefix}-oidc", auth.api.get_sso_provider(headers: {"cookie" => cookie}, query: {providerId: "#{prefix}-oidc"}).fetch("providerId")

    with_oidc_network_stubs(prefix) do
      state = Rack::Utils.parse_query(URI.parse(auth.api.sign_in_sso(body: {providerId: "#{prefix}-oidc", callbackURL: "/dashboard"}).fetch(:url)).query).fetch("state")
      status, headers, _body = auth.api.callback_sso(params: {providerId: "#{prefix}-oidc"}, query: {state: state, code: "good-code"}, as_response: true)

      assert_equal 302, status
      assert_equal "/dashboard", headers.fetch("location")
      user = auth.context.internal_adapter.find_user_by_email("#{prefix}-oidc-user@example.com").fetch(:user)
      assert auth.context.adapter.find_one(model: "session", where: [{field: "userId", value: user.fetch("id")}])
      assert auth.context.internal_adapter.find_account_by_provider_id("#{prefix}-oidc-sub", "sso:#{prefix}-oidc")
    end

    saml_provider = register_saml_provider(auth, cookie: cookie, provider_id: "#{prefix}-saml", domain: "#{prefix}-saml.example.com")
    verify_provider_domain(auth, cookie, saml_provider)
    sign_in = auth.api.sign_in_sso(body: {providerId: "#{prefix}-saml", callbackURL: "/dashboard"})
    request_id = saml_request_id_from_url(sign_in.fetch(:url))
    relay_state = Rack::Utils.parse_query(URI.parse(sign_in.fetch(:url)).query).fetch("RelayState")
    status, headers, _body = auth.api.acs_endpoint(
      params: {providerId: "#{prefix}-saml"},
      body: {SAMLResponse: saml_response_xml(in_response_to: request_id, assertion_id: "#{prefix}-assertion"), RelayState: relay_state},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/dashboard", headers.fetch("location")
    assert_nil auth.context.internal_adapter.find_verification_value("saml-authn-request:#{request_id}")
    assert auth.context.internal_adapter.find_verification_value("saml-used-assertion:#{prefix}-assertion")
  end

  def verify_provider_domain(auth, cookie, provider)
    identifier = "_better-auth-token-#{provider.fetch("providerId")}"
    @domain_tokens[identifier] = provider.fetch(:domainVerificationToken)
    response = auth.api.verify_domain(headers: {"cookie" => cookie}, body: {providerId: provider.fetch("providerId")}, return_status: true)
    assert_equal 204, response.fetch(:status)
  end

  def serializable_oidc_config(prefix)
    {
      clientId: "client-id",
      clientSecret: "client-secret",
      skipDiscovery: true,
      pkce: false,
      authorizationEndpoint: "https://idp.example.com/authorize",
      tokenEndpoint: "https://idp.example.com/token",
      userInfoEndpoint: "https://idp.example.com/userinfo",
      jwksEndpoint: "https://idp.example.com/jwks",
      mapping: {
        id: "sub",
        email: "email",
        name: "name"
      }
    }
  end

  def with_oidc_network_stubs(prefix)
    with_singleton_method(BetterAuth::Plugins, :sso_exchange_oidc_code, ->(**_kwargs) { {accessToken: "matrix-token"} }) do
      with_singleton_method(BetterAuth::Plugins, :sso_fetch_oidc_user_info, ->(_endpoint, _access_token, **_kwargs) {
        {sub: "#{prefix}-oidc-sub", email: "#{prefix}-oidc-user@example.com", name: "Matrix OIDC"}
      }) do
        yield
      end
    end
  end

  def with_singleton_method(object, method_name, replacement)
    singleton_class = class << object; self; end
    original = singleton_class.instance_method(method_name)
    redefine_without_warning(singleton_class, method_name) { |*args, **kwargs, &block| replacement.call(*args, **kwargs, &block) }
    yield
  ensure
    redefine_without_warning(singleton_class, method_name, original)
  end

  def redefine_without_warning(singleton_class, method_name, original = nil, &block)
    previous_verbose = $VERBOSE
    $VERBOSE = nil
    original ? singleton_class.define_method(method_name, original) : singleton_class.define_method(method_name, &block)
  ensure
    $VERBOSE = previous_verbose
  end

  def create_sql_schema(connection, config, dialect)
    BetterAuth::Schema::SQL.create_statements(config, dialect: dialect).each do |statement|
      case dialect
      when :postgres
        connection.exec(statement)
      when :mysql
        connection.query(statement)
      when :mssql
        connection.run(statement)
      else
        connection.execute(statement)
      end
    end
  end

  def reset_postgres_schema(connection)
    connection.exec(<<~SQL)
      DO $$ DECLARE r RECORD;
      BEGIN
        FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
          EXECUTE 'DROP TABLE IF EXISTS "' || r.tablename || '" CASCADE';
        END LOOP;
      END $$;
    SQL
  end

  def mysql_connection
    Mysql2::Client.new(
      host: ENV.fetch("BETTER_AUTH_MYSQL_HOST", "127.0.0.1"),
      port: ENV.fetch("BETTER_AUTH_MYSQL_PORT", "3306").to_i,
      username: ENV.fetch("BETTER_AUTH_MYSQL_USER", "user"),
      password: ENV.fetch("BETTER_AUTH_MYSQL_PASSWORD", "password"),
      database: ENV.fetch("BETTER_AUTH_MYSQL_DATABASE", "better_auth"),
      symbolize_keys: false
    )
  end

  def reset_mysql_schema(connection)
    connection.query("SET FOREIGN_KEY_CHECKS = 0")
    connection.query("SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE()").each do |row|
      table = row["table_name"] || row["TABLE_NAME"]
      connection.query("DROP TABLE IF EXISTS `#{table.to_s.gsub("`", "``")}`")
    end
  ensure
    connection&.query("SET FOREIGN_KEY_CHECKS = 1")
  end

  def ensure_mssql_database
    require "sequel"
    master = Sequel.connect(ENV.fetch("BETTER_AUTH_MSSQL_MASTER_URL", "tinytds://sa:Password123!@127.0.0.1:1433/master?timeout=30"))
    master.run("IF DB_ID(N'better_auth') IS NULL CREATE DATABASE [better_auth]")
  ensure
    master&.disconnect
  end

  def reset_mssql_schema(connection)
    connection.run(<<~SQL)
      DECLARE @sql NVARCHAR(MAX) = N''
      SELECT @sql = @sql + N'ALTER TABLE ' + QUOTENAME(SCHEMA_NAME(parent_table.schema_id)) + N'.' + QUOTENAME(parent_table.name) + N' DROP CONSTRAINT ' + QUOTENAME(foreign_key.name) + CHAR(10)
      FROM sys.foreign_keys AS foreign_key
      INNER JOIN sys.tables AS parent_table ON foreign_key.parent_object_id = parent_table.object_id
      EXEC sp_executesql @sql
    SQL
    connection.fetch("SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'").all.each do |row|
      table = row[:TABLE_NAME] || row[:table_name] || row["TABLE_NAME"] || row["table_name"]
      connection.run("DROP TABLE [#{table.to_s.gsub("]", "]]")}]") if table
    end
  end
end
