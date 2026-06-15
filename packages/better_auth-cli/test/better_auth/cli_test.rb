# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../../better_auth/lib", __dir__)

require "better_auth/cli"
require "minitest/autorun"
require_relative "../support/cli_helpers"

class BetterAuthCLITest < Minitest::Test
  include BetterAuthCLITestHelpers

  SECRET = BetterAuthCLITestHelpers::SECRET
  HARDENED_SECRET = BetterAuthCLITestHelpers::HARDENED_SECRET

  def teardown
    BetterAuth::CLI.configure(nil)
  end

  def test_generate_accepts_hash_config_and_writes_full_sql_for_memory_adapter
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_hash_config(dir, secret: SECRET, database: :memory, email_and_password: {enabled: true})
      output = File.join(dir, "auth.sql")

      status, stdout, stderr = run_cli("generate", "--config", config_path, "--dialect", "sqlite", "--output", output)

      assert_equal 0, status, stderr
      assert_includes stdout, "generated #{output}"
      assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "users"'
    end
  end

  def test_generate_accepts_configuration_return
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_config(
        dir,
        <<~RUBY
          BetterAuth::Configuration.new(
            secret: #{SECRET.inspect},
            database: :memory,
            email_and_password: {enabled: true}
          )
        RUBY
      )
      output = File.join(dir, "auth.sql")

      status, _stdout, stderr = run_cli("generate", "--config", config_path, "--dialect", "sqlite", "--output", output)

      assert_equal 0, status, stderr
      assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "users"'
    end
  end

  def test_generate_accepts_auth_return
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_config(
        dir,
        <<~RUBY
          BetterAuth.auth(
            secret: #{SECRET.inspect},
            database: :memory,
            email_and_password: {enabled: true}
          )
        RUBY
      )
      output = File.join(dir, "auth.sql")

      status, _stdout, stderr = run_cli("generate", "--config", config_path, "--dialect", "sqlite", "--output", output)

      assert_equal 0, status, stderr
      assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "users"'
    end
  end

  def test_generate_accepts_cli_configure_block
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_config(
        dir,
        <<~RUBY
          BetterAuth::CLI.configure do
            {
              secret: #{SECRET.inspect},
              database: :memory,
              email_and_password: {enabled: true}
            }
          end
          nil
        RUBY
      )
      output = File.join(dir, "auth.sql")

      status, _stdout, stderr = run_cli("generate", "--config", config_path, "--dialect", "sqlite", "--output", output)

      assert_equal 0, status, stderr
      assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "users"'
    end
  end

  def test_missing_config_file_returns_error
    Dir.mktmpdir("better-auth-cli") do |dir|
      status, _stdout, stderr = run_cli("doctor", "--config", File.join(dir, "missing.rb"))

      assert_equal 1, status
      assert_includes stderr, "Config file not found"
    end
  end

  def test_invalid_config_return_reports_allowed_types
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_config(dir, "42")

      status, _stdout, stderr = run_cli("doctor", "--config", config_path)

      assert_equal 1, status
      assert_includes stderr, "Hash, BetterAuth::Configuration, or BetterAuth::Auth"
    end
  end

  def test_help_with_no_args_lists_all_commands
    status, stdout, stderr = run_cli

    assert_equal 0, status, stderr
    assert_usage_lists_commands(stdout)
  end

  def test_help_flag_variants_list_all_commands
    %w[help --help -h].each do |flag|
      status, stdout, stderr = run_cli(flag)

      assert_equal 0, status, "#{flag}: #{stderr}"
      assert_usage_lists_commands(stdout)
    end
  end

  def test_unknown_command_returns_error
    status, stdout, stderr = run_cli("wat")

    assert_equal 1, status
    assert_empty stdout
    assert_includes stderr, "Unknown command: wat"
  end

  def test_unknown_mongo_subcommand_returns_error
    status, stdout, stderr = run_cli("mongo", "wat")

    assert_equal 1, status
    assert_empty stdout
    assert_includes stderr, "Unknown mongo command: wat"
  end

  def test_missing_mongo_subcommand_returns_error
    status, stdout, stderr = run_cli("mongo")

    assert_equal 1, status
    assert_empty stdout
    assert_includes stderr, "Unknown mongo command: (none)"
  end

  def test_config_eval_error_returns_status_without_backtrace
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_config(dir, "raise RuntimeError, \"boom\"")

      status, stdout, stderr = run_cli("doctor", "--config", config_path)

      assert_equal 1, status
      assert_empty stdout
      assert_includes stderr, "boom"
      refute_includes stderr, "backtrace"
      refute_includes stderr, "cli_test.rb"
    end
  end

  def test_config_load_does_not_leak_cli_configure_state
    Dir.mktmpdir("better-auth-cli") do |dir|
      configure_path = write_config(
        dir,
        <<~RUBY
          BetterAuth::CLI.configure do
            {
              secret: #{SECRET.inspect},
              database: :memory,
              email_and_password: {enabled: true}
            }
          end
          nil
        RUBY
      )
      invalid_path = write_config(dir, "42", filename: "invalid.rb")

      status, _stdout, stderr = run_cli("doctor", "--config", configure_path)
      assert_equal 0, status, stderr

      status, stdout, stderr = run_cli("doctor", "--config", invalid_path)

      assert_equal 1, status
      assert_empty stdout
      assert_includes stderr, "Hash, BetterAuth::Configuration, or BetterAuth::Auth"
    end
  end

  def test_better_auth_executable_help_lists_commands
    stdout, stderr, status = run_better_auth_executable("--help")

    assert status.success?, stderr
    assert_usage_lists_commands(stdout)
  end

  def test_better_auth_executable_generate_writes_sql
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_hash_config(dir, secret: SECRET, database: :memory, email_and_password: {enabled: true})
      output = File.join(dir, "auth.sql")

      stdout, stderr, status = run_better_auth_executable(
        "generate",
        "--config",
        config_path,
        "--dialect",
        "sqlite",
        "--output",
        output
      )

      assert status.success?, stderr
      assert_includes stdout, "generated #{output}"
      assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "users"'
    end
  end

  def test_better_auth_executable_unknown_command_returns_error
    stdout, stderr, status = run_better_auth_executable("wat")

    assert_equal false, status.success?
    assert_empty stdout
    assert_includes stderr, "Unknown command: wat"
  end

  def test_missing_required_options_return_errors
    status, _stdout, stderr = run_cli("generate", "--config", "config.rb")
    assert_equal 1, status
    assert_includes stderr, "generate --output PATH is required"

    status, _stdout, stderr = run_cli("migrate")
    assert_equal 1, status
    assert_includes stderr, "migrate --config PATH is required"

    status, _stdout, stderr = run_cli("doctor")
    assert_equal 1, status
    assert_includes stderr, "doctor --config PATH is required"
  end

  def test_invalid_option_returns_error_status
    status, _stdout, stderr = run_cli("generate", "--bogus")

    assert_equal 1, status
    assert_includes stderr, "invalid option: --bogus"
  end

  def test_missing_option_argument_returns_error_status
    status, _stdout, stderr = run_cli("generate", "--config")

    assert_equal 1, status
    assert_includes stderr, "missing argument: --config"
  end

  def test_migrate_requires_yes
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir)

      status, _stdout, stderr = run_cli("migrate", "--config", config_path)

      assert_equal 1, status
      assert_includes stderr, "Pass --yes to apply migrations."
    end
  end

  def test_generate_writes_incremental_sql
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir)
      output = File.join(dir, "auth.sql")

      status, stdout, stderr = run_cli("generate", "--config", config_path, "--dialect", "sqlite", "--output", output)

      assert_equal 0, status, stderr
      assert_includes stdout, "generated #{output}"
      assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "users"'
    end
  end

  def test_generate_reports_no_migrations_needed_without_writing_output
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir)
      output = File.join(dir, "auth.sql")

      status, _stdout, stderr = run_cli("migrate", "--config", config_path, "--yes")
      assert_equal 0, status, stderr

      status, stdout, stderr = run_cli("generate", "--config", config_path, "--dialect", "sqlite", "--output", output)

      assert_equal 0, status, stderr
      assert_includes stdout, "No migrations needed."
      refute File.exist?(output)
    end
  end

  def test_generate_includes_plugin_schema
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(
        dir,
        plugins_source: <<~RUBY.strip
          [
            BetterAuth::Plugin.new(
              id: "audit",
              schema: {
                auditLog: {
                  model_name: "audit_logs",
                  fields: {
                    id: {type: "string", required: true},
                    action: {type: "string", required: true, index: true}
                  }
                }
              }
            )
          ]
        RUBY
      )
      output = File.join(dir, "auth.sql")

      status, _stdout, stderr = run_cli("generate", "--config", config_path, "--dialect", "sqlite", "--output", output)

      assert_equal 0, status, stderr
      assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "audit_logs"'
    end
  end

  def test_generate_includes_database_rate_limit_table
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir, rate_limit: {enabled: true, storage: "database"})
      output = File.join(dir, "auth.sql")

      status, _stdout, stderr = run_cli("generate", "--config", config_path, "--dialect", "sqlite", "--output", output)

      assert_equal 0, status, stderr
      assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "rate_limits"'
    end
  end

  def test_migrate_applies_pending_schema_and_repeated_migrate_reports_no_changes
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir)

      status, stdout, stderr = run_cli("migrate", "--config", config_path, "--yes")
      assert_equal 0, status, stderr
      assert_includes stdout, "migration completed successfully."
      assert_includes sqlite_tables(dir), "users"

      status, stdout, stderr = run_cli("migrate", "--config", config_path, "--yes")
      assert_equal 0, status, stderr
      assert_includes stdout, "No migrations needed."
    end
  end

  def test_migrate_status_lists_pending_schema_before_migration_and_no_changes_after
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir)

      status, stdout, stderr = run_cli("migrate", "status", "--config", config_path)
      assert_equal 0, status, stderr
      assert_includes stdout, "create table users"

      status, _stdout, stderr = run_cli("migrate", "--config", config_path, "--yes")
      assert_equal 0, status, stderr

      status, stdout, stderr = run_cli("migrate", "status", "--config", config_path)
      assert_equal 0, status, stderr
      assert_includes stdout, "No migrations needed."
    end
  end

  def test_migrate_reports_unsupported_adapter
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_hash_config(dir, secret: SECRET, database: :memory)

      status, _stdout, stderr = run_cli("migrate", "--config", config_path, "--yes")

      assert_equal 1, status
      assert_includes stderr, "SQL adapters"
    end
  end

  def test_doctor_reports_insecure_secret_and_pending_migrations
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(
        dir,
        secret: BetterAuth::Configuration::DEFAULT_SECRET,
        base_url: "http://example.test"
      )

      status, stdout, stderr = run_cli("doctor", "--config", config_path)

      assert_equal 1, status
      assert_includes stderr, "ERROR secret uses the default development value"
      assert_includes stdout, "WARN base_url is not HTTPS"
      assert_includes stdout, "WARN rate_limit uses memory storage"
      assert_includes stdout, "WARN database has pending Better Auth migrations"
    end
  end

  def test_doctor_passes_for_hardened_config_after_migration
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(
        dir,
        secret: HARDENED_SECRET,
        base_url: "https://example.test",
        rate_limit: {enabled: true, storage: "database"}
      )
      status, _stdout, stderr = run_cli("migrate", "--config", config_path, "--yes")
      assert_equal 0, status, stderr

      status, stdout, stderr = run_cli("doctor", "--config", config_path)

      assert_equal 0, status, stderr
      assert_includes stdout, "OK config loaded"
      assert_includes stdout, "OK secret length and entropy look acceptable"
      assert_includes stdout, "OK database schema is up to date"
      assert_includes stdout, "OK rate_limit storage is database"
    end
  end

  def test_doctor_warns_when_rate_limit_is_disabled
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_hash_config(
        dir,
        secret: HARDENED_SECRET,
        base_url: "https://example.test",
        database: :memory,
        rate_limit: {enabled: false, storage: "memory"}
      )

      status, stdout, stderr = run_cli("doctor", "--config", config_path)

      assert_equal 0, status, stderr
      assert_includes stdout, "WARN rate_limit is disabled"
      assert_includes stdout, "WARN rate_limit uses memory storage"
      assert_includes stdout, "WARN database adapter does not expose SQL migration introspection"
    end
  end

  def test_doctor_accepts_secondary_storage_rate_limit_without_memory_warning
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_hash_config(
        dir,
        secret: HARDENED_SECRET,
        base_url: "https://example.test",
        database: :memory,
        rate_limit: {enabled: true, storage: "secondary-storage"}
      )

      status, stdout, stderr = run_cli("doctor", "--config", config_path)

      assert_equal 0, status, stderr
      assert_includes stdout, "OK rate_limit storage is secondary-storage"
      refute_includes stdout, "rate_limit uses memory storage"
    end
  end

  def test_fake_sql_adapters_cover_generate_and_status_for_all_supported_dialects
    {
      sqlite: '"users"',
      postgres: '"users"',
      mysql: "`users`",
      mssql: "[users]"
    }.each do |dialect, quoted_users|
      Dir.mktmpdir("better-auth-cli") do |dir|
        config_path = write_fake_sql_config(dir, dialect: dialect)
        output = File.join(dir, "#{dialect}.sql")

        status, _stdout, stderr = run_cli("generate", "--config", config_path, "--output", output)
        assert_equal 0, status, "#{dialect}: #{stderr}"
        assert_includes File.read(output), "CREATE TABLE"
        assert_includes File.read(output), quoted_users

        status, stdout, stderr = run_cli("migrate", "status", "--config", config_path)
        assert_equal 0, status, "#{dialect}: #{stderr}"
        assert_includes stdout, "create table users"
      end
    end
  end

  def test_mongo_indexes_calls_adapter_index_setup
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_mongo_config(
        dir,
        indexes: [
          {collection: "users", field: "email", unique: true},
          {collection: "sessions", field: "token", unique: false}
        ]
      )

      status, stdout, stderr = run_cli("mongo", "indexes", "--config", config_path)

      assert_equal 0, status, stderr
      assert_includes stdout, "ensured unique index users.email"
      assert_includes stdout, "ensured index sessions.token"
    end
  end

  def test_mongo_indexes_reports_no_indexes_needed
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_mongo_config(dir, indexes: [])

      status, stdout, stderr = run_cli("mongo", "indexes", "--config", config_path)

      assert_equal 0, status, stderr
      assert_includes stdout, "No MongoDB indexes needed."
    end
  end

  def test_mongo_indexes_reports_malformed_index_metadata
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_mongo_config(dir, indexes: [{collection: "users", unique: true}])

      status, _stdout, stderr = run_cli("mongo", "indexes", "--config", config_path)

      assert_equal 1, status
      assert_includes stderr, "MongoDB index metadata must include collection and field"
    end
  end

  def test_mongo_indexes_reports_unsupported_adapter
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_hash_config(dir, secret: SECRET, database: :memory)

      status, _stdout, stderr = run_cli("mongo", "indexes", "--config", config_path)

      assert_equal 1, status
      assert_includes stderr, "ensure_indexes"
    end
  end

  def test_generate_with_custom_model_names_writes_custom_tables
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(
        dir,
        user_options_source: "{model_name: \"custom_users\"}",
        session_options_source: "{model_name: \"custom_sessions\"}",
        account_options_source: "{model_name: \"custom_accounts\"}",
        verification_options_source: "{model_name: \"custom_verifications\"}"
      )
      output = File.join(dir, "auth.sql")

      status, _stdout, stderr = run_cli("generate", "--config", config_path, "--dialect", "sqlite", "--output", output)

      assert_equal 0, status, stderr
      sql = File.read(output)
      assert_includes sql, 'CREATE TABLE IF NOT EXISTS "custom_users"'
      assert_includes sql, 'REFERENCES "custom_users" ("id")'
    end
  end

  def test_generate_json_and_array_fields_use_dialect_specific_types
    plugins_source = <<~RUBY.strip
      [
        BetterAuth::Plugin.new(
          id: "typed",
          schema: {
            auditLog: {
              model_name: "audit_logs",
              fields: {
                metadata: {type: "json", required: false},
                tags: {type: "string[]", required: false}
              }
            }
          }
        )
      ]
    RUBY

    Dir.mktmpdir("better-auth-cli") do |dir|
      sqlite_config = write_fake_sql_config(dir, dialect: :sqlite, plugins_source: plugins_source)
      postgres_config = write_fake_sql_config(dir, dialect: :postgres, plugins_source: plugins_source)
      sqlite_out = File.join(dir, "sqlite.sql")
      postgres_out = File.join(dir, "postgres.sql")

      status, _stdout, stderr = run_cli("generate", "--config", sqlite_config, "--dialect", "sqlite", "--output", sqlite_out)
      assert_equal 0, status, stderr
      status, _stdout, stderr = run_cli("generate", "--config", postgres_config, "--dialect", "postgres", "--output", postgres_out)
      assert_equal 0, status, stderr

      assert_includes File.read(sqlite_out), '"metadata" text'
      assert_includes File.read(postgres_out), '"metadata" jsonb'
    end
  end

  def test_migrate_status_lists_plugin_table_and_indexes
    plugins_source = <<~RUBY.strip
      [
        BetterAuth::Plugin.new(
          id: "indexed-plugin",
          schema: {
            auditLog: {
              model_name: "audit_logs",
              fields: {
                action: {type: "string", required: true, index: true}
              }
            }
          }
        )
      ]
    RUBY

    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir, plugins_source: plugins_source)

      status, stdout, stderr = run_cli("migrate", "status", "--config", config_path)

      assert_equal 0, status, stderr
      assert_includes stdout, "create table audit_logs"
      assert_includes stdout, "create index index_audit_logs_on_action"
    end
  end

  def test_migrate_status_reports_new_plugin_table_after_core_migration
    Dir.mktmpdir("better-auth-cli") do |dir|
      base_config = write_sqlite_config(dir)

      status, _stdout, stderr = run_cli("migrate", "--config", base_config, "--yes")
      assert_equal 0, status, stderr

      plugin_config = write_sqlite_config(dir, plugins_source: "[BetterAuth::Plugins.two_factor]")
      status, stdout, stderr = run_cli("migrate", "status", "--config", plugin_config)

      assert_equal 0, status, stderr
      assert_includes stdout, "create table two_factors"
    end
  end

  def test_migrate_after_cli_migrate_supports_email_sign_up
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir)

      status, _stdout, stderr = run_cli("migrate", "--config", config_path, "--yes")
      assert_equal 0, status, stderr

      auth = auth_for_sqlite_dir(dir)
      result = auth.api.sign_up_email(
        body: {email: "cli-migrate@example.com", password: "password123", name: "CLI Migrate"}
      )

      assert_match(/\A[0-9a-f]{32}\z/, result[:token])
      assert_equal "cli-migrate@example.com", result[:user]["email"]
      account = auth.context.adapter.find_one(
        model: "account",
        where: [{field: "userId", value: result[:user]["id"]}]
      )
      assert_equal "credential", account["providerId"]
      assert_includes sqlite_tables(dir), "sessions"
    end
  end

  def test_migrate_creates_writable_plugin_table
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir, plugins_source: audit_plugin_source)

      status, _stdout, stderr = run_cli("migrate", "--config", config_path, "--yes")
      assert_equal 0, status, stderr
      assert_includes sqlite_tables(dir), "audit_logs"

      record_id = "audit-#{dir.hash.abs}"
      db = SQLite3::Database.new(sqlite_db_path(dir))
      db.execute(
        "INSERT INTO audit_logs (id, action) VALUES (?, ?)",
        [record_id, "login"]
      )
      row = db.execute("SELECT action FROM audit_logs WHERE id = ?", [record_id]).first
      db.close

      assert_equal "login", row[0]
    end
  end

  def test_migrate_status_reports_add_fields_to_existing_table
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir)
      status, _stdout, stderr = run_cli("migrate", "--config", config_path, "--yes")
      assert_equal 0, status, stderr

      extended_config = write_sqlite_config(
        dir,
        user_options_source: "{additional_fields: {role: {type: \"string\", required: false}}}"
      )
      status, stdout, stderr = run_cli("migrate", "status", "--config", extended_config)

      assert_equal 0, status, stderr
      assert_includes stdout, "add role to users"
    end
  end

  def test_migrate_status_reports_missing_index_for_indexed_additional_field
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir)
      status, _stdout, stderr = run_cli("migrate", "--config", config_path, "--yes")
      assert_equal 0, status, stderr

      extended_config = write_sqlite_config(
        dir,
        user_options_source: "{additional_fields: {badge: {type: \"string\", required: false, index: true}}}"
      )
      status, stdout, stderr = run_cli("migrate", "status", "--config", extended_config)

      assert_equal 0, status, stderr
      assert_includes stdout, "create index index_users_on_badge"
    end
  end

  def test_migrate_status_reports_type_mismatch_warnings
    Dir.mktmpdir("better-auth-cli") do |dir|
      db_path = sqlite_db_path(dir)
      connection = SQLite3::Database.new(db_path)
      connection.execute('CREATE TABLE "users" ("id" text PRIMARY KEY, "email" integer);')
      connection.close

      config_path = write_sqlite_config(dir)
      status, stdout, stderr = run_cli("migrate", "status", "--config", config_path)

      assert_equal 0, status, stderr
      assert_includes stdout, "warning:"
      assert_includes stdout, "users.email"
    end
  end

  def test_migrate_status_has_no_duplicate_pending_entries_after_migration
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(
        dir,
        user_options_source: "{additional_fields: {role: {type: \"string\", required: false}}}"
      )

      status, stdout, stderr = run_cli("migrate", "status", "--config", config_path)
      assert_equal 0, status, stderr
      pending_lines = stdout.lines.map(&:strip).reject(&:empty?)
      assert_equal pending_lines, pending_lines.uniq

      status, _stdout, stderr = run_cli("migrate", "--config", config_path, "--yes")
      assert_equal 0, status, stderr

      status, stdout, stderr = run_cli("migrate", "status", "--config", config_path)
      assert_equal 0, status, stderr
      assert_includes stdout, "No migrations needed."
    end
  end

  def test_doctor_reports_short_and_low_entropy_secrets
    Dir.mktmpdir("better-auth-cli") do |dir|
      short_config = write_sqlite_config(dir, secret: "short")
      status, _stdout, stderr = run_cli("doctor", "--config", short_config)
      assert_equal 1, status
      assert_includes stderr, "at least 32 characters"

      low_entropy_config = write_sqlite_config(dir, secret: "a" * 32)
      status, _stdout, stderr = run_cli("doctor", "--config", low_entropy_config)
      assert_equal 1, status
      assert_includes stderr, "low-entropy"
    end
  end

  def test_doctor_reports_missing_base_url_and_secondary_storage_rate_limit_ok
    Dir.mktmpdir("better-auth-cli") do |dir|
      missing_base_url = write_hash_config(
        dir,
        secret: HARDENED_SECRET,
        database: :memory,
        filename: "no_base_url.rb"
      )
      status, stdout, stderr = run_cli("doctor", "--config", missing_base_url)
      assert_equal 0, status, stderr
      assert_includes stdout, "WARN base_url is not configured"

      secondary_config = write_hash_config(
        dir,
        secret: HARDENED_SECRET,
        database: :memory,
        rate_limit: {enabled: true, storage: "secondary-storage"},
        filename: "secondary_rate_limit.rb"
      )
      status, stdout, stderr = run_cli("doctor", "--config", secondary_config)
      assert_equal 0, status, stderr
      assert_includes stdout, "OK rate_limit storage is secondary-storage"
    end
  end

  def test_doctor_skips_schema_drift_for_memory_adapter
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_hash_config(dir, secret: HARDENED_SECRET, database: :memory)

      status, stdout, stderr = run_cli("doctor", "--config", config_path)

      assert_equal 0, status, stderr
      assert_includes stdout, "WARN database adapter does not expose SQL migration introspection"
    end
  end

  def test_doctor_surfaces_type_mismatch_warnings_from_planner
    Dir.mktmpdir("better-auth-cli") do |dir|
      db_path = sqlite_db_path(dir)
      connection = SQLite3::Database.new(db_path)
      connection.execute('CREATE TABLE "users" ("id" text PRIMARY KEY, "email" integer);')
      connection.close

      config_path = write_sqlite_config(dir, secret: HARDENED_SECRET, base_url: "https://example.test")
      status, stdout, stderr = run_cli("doctor", "--config", config_path)

      assert_equal 0, status, stderr
      assert_includes stdout, "WARN database has pending Better Auth migrations"
      assert stdout.lines.any? { |line| line.include?("users.email") }
    end
  end

  def test_generate_with_unsupported_field_type_returns_error
    plugins_source = <<~RUBY.strip
      [
        BetterAuth::Plugin.new(
          id: "bad-type",
          schema: {
            auditLog: {
              model_name: "audit_logs",
              fields: {
                payload: {type: "object", required: false}
              }
            }
          }
        )
      ]
    RUBY

    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_fake_sql_config(dir, dialect: :postgres, plugins_source: plugins_source)
      output = File.join(dir, "out.sql")

      status, stdout, stderr = run_cli("generate", "--config", config_path, "--dialect", "postgres", "--output", output)

      assert_equal 1, status
      assert_empty stdout
      assert_includes stderr, "Unsupported field type: object"
      refute File.exist?(output)
    end
  end

  def test_better_auth_executable_is_packaged
    spec = Gem::Specification.load(File.expand_path("../../better_auth-cli.gemspec", __dir__))

    assert_includes spec.executables, "better-auth"
    refute_includes spec.executables, "openauth"
  end

  private

  def assert_usage_lists_commands(usage)
    assert_includes usage, "better-auth generate"
    assert_includes usage, "better-auth migrate"
    assert_includes usage, "migrate status"
    assert_includes usage, "better-auth doctor"
    assert_includes usage, "mongo indexes"
  end
end
