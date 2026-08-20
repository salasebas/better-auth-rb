# frozen_string_literal: true

require "json"
require_relative "../../test_helper"
require_relative "adapter_contract"

class BetterAuthMySQLAdapterTest < Minitest::Test
  include BetterAuthMySQLTestHelpers
  include BetterAuthAdapterContract

  SECRET = "test-secret-that-is-long-enough-for-validation"

  def test_mysql_url_preserves_documented_driver_options_without_connecting
    url = "mysql2://user+name:p%2Bass@db.example:3307/app%2Ftenant?" \
      "socket=%2Ftmp%2Fmysql%2Bsock&encoding=utf8mb4&flags=FOUND_ROWS+-COMPRESS&" \
      "sslkey=%2Fcerts%2Fclient-key.pem&sslcert=%2Fcerts%2Fclient-cert.pem&" \
      "sslca=%2Fcerts%2Fca.pem&sslcapath=%2Fcerts&sslcipher=TLS_AES_256_GCM_SHA384&" \
      "default_file=%2Fetc%2Fmy.cnf&default_group=client&default_auth=caching_sha2_password&" \
      "init_command=SET%20sql_mode%3D%27STRICT_ALL_TABLES%27&" \
      "connect_timeout=7&read_timeout=8&write_timeout=9&" \
      "reconnect=true&local_infile=false&secure_auth=true&" \
      "get_server_public_key=false&sslverify=true&ssl_mode=verify_identity"

    options = mysql_client_options(url: url)

    assert_equal(
      {
        host: "db.example",
        port: 3307,
        username: "user+name",
        password: "p+ass",
        database: "app/tenant",
        socket: "/tmp/mysql+sock",
        encoding: "utf8mb4",
        flags: "FOUND_ROWS -COMPRESS",
        sslkey: "/certs/client-key.pem",
        sslcert: "/certs/client-cert.pem",
        sslca: "/certs/ca.pem",
        sslcapath: "/certs",
        sslcipher: "TLS_AES_256_GCM_SHA384",
        default_file: "/etc/my.cnf",
        default_group: "client",
        default_auth: "caching_sha2_password",
        init_command: "SET sql_mode='STRICT_ALL_TABLES'",
        connect_timeout: 7,
        read_timeout: 8,
        write_timeout: 9,
        reconnect: true,
        local_infile: false,
        secure_auth: true,
        get_server_public_key: false,
        sslverify: true,
        ssl_mode: :verify_identity,
        symbolize_keys: false
      },
      options
    )
  end

  def test_mysql_url_uses_last_repeated_value_and_warns_for_unsupported_keys_without_values
    url = "mysql2://user:password@db.example/app?" \
      "read_timeout=3&read_timeout=11&host=attacker.example&pool=9&unknown=secret-value"

    _out, err = capture_io do
      @captured_mysql_options = mysql_client_options(url: url)
    end

    assert_equal 11, @captured_mysql_options[:read_timeout]
    assert_equal "db.example", @captured_mysql_options[:host]
    assert_includes err, 'Ignoring unsupported MySQL URL option: "host"'
    assert_includes err, 'Ignoring unsupported MySQL URL option: "pool"'
    assert_includes err, 'Ignoring unsupported MySQL URL option: "unknown"'
    refute_includes err, "attacker.example"
    refute_includes err, "secret-value"
  ensure
    @captured_mysql_options = nil
  end

  def test_explicit_mysql_connection_options_override_url_and_keep_string_row_keys
    connection_options = {
      host: "override.example",
      port: 4406,
      read_timeout: 12,
      ssl_mode: "VERIFY_IDENTITY",
      sslca: "/explicit-ca.pem",
      symbolize_keys: true
    }
    connection_options["host"] = connection_options.delete(:host)
    options = mysql_client_options(
      url: "mysql2://user:password@db.example:3306/app?read_timeout=3&ssl_mode=required&sslca=%2Furl-ca.pem",
      connection_options: connection_options
    )

    assert_equal "override.example", options[:host]
    assert_equal 4406, options[:port]
    assert_equal 12, options[:read_timeout]
    assert_equal :verify_identity, options[:ssl_mode]
    assert_equal "/explicit-ca.pem", options[:sslca]
    assert_equal false, options[:symbolize_keys]
  end

  def test_explicit_mysql_connection_bypasses_url_and_connection_options
    connection = Object.new

    adapter = BetterAuth::Adapters::MySQL.new(
      url: "not a valid URL %",
      connection: connection,
      connection_options: {unsupported: "ignored with an explicit connection"}
    )

    assert_same connection, adapter.connection
  end

  def test_mysql_url_rejects_invalid_typed_and_tls_options_before_connecting
    {
      "connect_timeout=0" => "MySQL option connect_timeout must be a positive integer",
      "read_timeout=not-a-number" => "MySQL option read_timeout must be a positive integer",
      "sslverify=1" => "MySQL option sslverify must be true or false",
      "ssl_mode=verify_peer" => "MySQL option ssl_mode must be one of: disabled, preferred, required, verify_ca, verify_identity"
    }.each do |query, message|
      error = assert_raises(ArgumentError) do
        mysql_client_options(url: "mysql2://user:password@db.example/app?#{query}")
      end

      assert_equal message, error.message
    end
  end

  def test_mysql_connection_options_reject_unknown_driver_keys
    error = assert_raises(ArgumentError) do
      mysql_client_options(
        url: "mysql2://user:password@db.example/app",
        connection_options: {unknown: true}
      )
    end

    assert_equal "Unsupported MySQL connection option: unknown", error.message
  end

  def test_mysql_adapter_can_be_instantiated_without_rails
    port = ENV.fetch("BETTER_AUTH_MYSQL_PORT", "3306")
    adapter = BetterAuth::Adapters::MySQL.new(url: "mysql2://user:password@127.0.0.1:#{port}/better_auth")

    assert_equal :mysql, adapter.dialect
  rescue LoadError
    skip "mysql2 gem is not installed"
  rescue Mysql2::Error::ConnectionError
    skip "MySQL test service is not available"
  end

  def test_mysql_adapter_runs_core_crud_against_docker_service
    require "mysql2"

    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory)
    connection = Mysql2::Client.new(
      host: ENV.fetch("BETTER_AUTH_MYSQL_HOST", "127.0.0.1"),
      port: ENV.fetch("BETTER_AUTH_MYSQL_PORT", "3306").to_i,
      username: ENV.fetch("BETTER_AUTH_MYSQL_USER", "user"),
      password: ENV.fetch("BETTER_AUTH_MYSQL_PASSWORD", "password"),
      database: ENV.fetch("BETTER_AUTH_MYSQL_DATABASE", "better_auth"),
      symbolize_keys: false
    )
    reset_mysql_schema(connection)
    BetterAuth::Schema::SQL.create_statements(config, dialect: :mysql).each { |statement| connection.query(statement) }
    adapter = BetterAuth::Adapters::MySQL.new(config, connection: connection)

    user = adapter.create(model: "user", data: {id: "user-1", name: "Ada", email: "ada@example.com"}, force_allow_id: true)
    found = adapter.find_one(model: "user", where: [{field: "email", value: "ada@example.com"}])

    assert_equal "user-1", user["id"]
    assert_equal false, user["emailVerified"]
    assert_equal "Ada", found["name"]
  rescue LoadError
    skip "mysql2 gem is not installed"
  rescue Mysql2::Error::ConnectionError
    skip "MySQL test service is not available"
  ensure
    connection&.close
  end

  def test_mysql_adapter_persists_auth_routes_and_get_session_reads_database_rows
    require "mysql2"

    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory)
    connection = mysql_connection
    reset_mysql_schema(connection)
    create_schema(connection, config)
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: ->(options) { BetterAuth::Adapters::MySQL.new(options, connection: connection) },
      email_and_password: {enabled: true},
      session: {cookie_cache: {enabled: false}}
    )

    status, headers, body = auth.api.sign_up_email(
      body: {email: "mysql-route@example.com", password: "password123", name: "MySQL Route"},
      as_response: true
    )
    payload = JSON.parse(body.join)
    token = payload.fetch("token")
    user_id = payload.fetch("user").fetch("id")

    assert_equal 200, status
    assert_equal "mysql-route@example.com", direct_mysql_value(connection, "SELECT email FROM `users` WHERE id = ?", user_id)
    assert_equal "credential", direct_mysql_value(connection, "SELECT provider_id FROM `accounts` WHERE user_id = ?", user_id)
    assert_equal user_id, direct_mysql_value(connection, "SELECT user_id FROM `sessions` WHERE token = ?", token)

    statement = connection.prepare("UPDATE `users` SET `name` = ? WHERE id = ?")
    statement.execute("MySQL Direct Update", user_id)
    session = auth.api.get_session(headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))})

    assert_equal token, session[:session]["token"]
    assert_equal user_id, session[:session]["userId"]
    assert_equal "MySQL Direct Update", session[:user]["name"]
  rescue LoadError
    skip "mysql2 gem is not installed"
  rescue Mysql2::Error::ConnectionError
    skip "MySQL test service is not available"
  ensure
    connection&.close
  end

  def test_mysql_pending_migration_does_not_recreate_existing_indexes
    require "mysql2"

    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory)
    connection = mysql_connection
    reset_mysql_schema(connection)
    create_schema(connection, config)

    sql = BetterAuth::SQLMigration.render_pending(config, connection: connection, dialect: :mysql, generator: "better_auth-test")

    refute_includes sql, "index_sessions_on_user_id"
    refute_includes sql, "index_accounts_on_user_id"
  rescue LoadError
    skip "mysql2 gem is not installed"
  rescue Mysql2::Error::ConnectionError
    skip "MySQL test service is not available"
  ensure
    connection&.close
  end

  def test_mysql_pending_migration_adds_plugin_table_after_core_schema
    require "mysql2"

    plugin = BetterAuth::Plugin.new(
      id: "audit",
      schema: {
        auditLog: {
          model_name: "audit_logs",
          fields: {
            id: {type: "string", required: true},
            userId: {type: "string", required: true, references: {model: "user", field: "id"}, index: true},
            action: {type: "string", required: true, index: true}
          }
        }
      }
    )
    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory)
    plugin_config = BetterAuth::Configuration.new(secret: SECRET, database: :memory, plugins: [plugin])
    connection = mysql_connection
    reset_mysql_schema(connection)
    create_schema(connection, config)

    sql = BetterAuth::SQLMigration.render_pending(plugin_config, connection: connection, dialect: :mysql, generator: "better_auth-test")

    assert_includes sql, "CREATE TABLE IF NOT EXISTS `audit_logs`"
    assert_includes sql, "CONSTRAINT `fk_audit_logs_user_id` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE"

    BetterAuth::SQLMigration.execute_sql(connection, sql)

    assert_includes mysql_table_names(connection), "audit_logs"
  rescue LoadError
    skip "mysql2 gem is not installed"
  rescue Mysql2::Error::ConnectionError
    skip "MySQL test service is not available"
  ensure
    connection&.close
  end

  private

  def mysql_client_options(url:, connection_options: nil)
    require "mysql2"

    captured = nil
    connection = Object.new
    keywords = {url: url}
    keywords[:connection_options] = connection_options unless connection_options.nil?
    client_constructor = lambda do |options|
      captured = options
      connection
    end
    Mysql2::Client.stub(:new, client_constructor) do
      adapter = BetterAuth::Adapters::MySQL.new(**keywords)
      assert_same connection, adapter.connection
    end
    captured
  rescue LoadError
    skip "mysql2 gem is not installed"
  end

  def with_contract_adapter(config)
    require "mysql2"

    connection = mysql_connection
    reset_mysql_schema(connection)
    create_schema(connection, config)
    yield BetterAuth::Adapters::MySQL.new(config, connection: connection)
  rescue LoadError
    skip "mysql2 gem is not installed"
  rescue Mysql2::Error::ConnectionError
    skip "MySQL test service is not available"
  ensure
    connection&.close
  end

  def create_schema(connection, config)
    BetterAuth::Schema::SQL.create_statements(config, dialect: :mysql).each { |statement| connection.query(statement) }
  end

  def direct_mysql_value(connection, sql, *params)
    statement = connection.prepare(sql)
    statement.execute(*params).first&.values&.first
  end

  def cookie_header(set_cookie)
    set_cookie.lines.map { |line| line.split(";").first }.join("; ")
  end
end
