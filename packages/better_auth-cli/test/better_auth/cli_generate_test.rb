# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliGenerateTest < BetterAuthCLITestCase
  def test_generate_accepts_hash_config_and_writes_full_sql_for_memory_adapter
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_hash_config(dir, secret: SECRET, database: :memory, email_and_password: {enabled: true})
      output = File.join(dir, "auth.sql")

      status, stdout, stderr = run_cli("generate", "--cwd", dir, "--config", config_path, "--dialect", "sqlite", "--output", output)

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

      status, _stdout, stderr = run_cli("generate", "--cwd", dir, "--config", config_path, "--dialect", "sqlite", "--output", output)

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

      status, _stdout, stderr = run_cli("generate", "--cwd", dir, "--config", config_path, "--dialect", "sqlite", "--output", output)

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

      status, _stdout, stderr = run_cli("generate", "--cwd", dir, "--config", config_path, "--dialect", "sqlite", "--output", output)

      assert_equal 0, status, stderr
      assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "users"'
    end
  end

  def test_better_auth_executable_generate_writes_sql
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_hash_config(dir, secret: SECRET, database: :memory, email_and_password: {enabled: true})
      output = File.join(dir, "auth.sql")

      stdout, stderr, status = run_better_auth_executable(
        "generate",
        "--cwd",
        dir,
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

  def test_generate_writes_incremental_sql
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir)
      output = File.join(dir, "auth.sql")

      status, stdout, stderr = run_cli("generate", "--cwd", dir, "--config", config_path, "--dialect", "sqlite", "--output", output)

      assert_equal 0, status, stderr
      assert_includes stdout, "generated #{output}"
      assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "users"'
    end
  end

  def test_generate_reports_no_migrations_needed_without_writing_output
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir)
      output = File.join(dir, "auth.sql")

      status, _stdout, stderr = run_cli("migrate", "--cwd", dir, "--config", config_path, "--yes")
      assert_equal 0, status, stderr

      status, stdout, stderr = run_cli("generate", "--cwd", dir, "--config", config_path, "--dialect", "sqlite", "--output", output)

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

      status, _stdout, stderr = run_cli("generate", "--cwd", dir, "--config", config_path, "--dialect", "sqlite", "--output", output)

      assert_equal 0, status, stderr
      assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "audit_logs"'
    end
  end

  def test_generate_omits_plugin_schema_with_migrations_disabled
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(
        dir,
        plugins_source: <<~RUBY.strip
          [
            BetterAuth::Plugin.new(
              id: "external-audit",
              schema: {
                auditLog: {
                  model_name: "audit_logs",
                  disableMigration: true,
                  fields: {
                    userId: {type: "string", required: true, references: {model: "user", field: "id"}, index: true}
                  }
                }
              }
            )
          ]
        RUBY
      )
      output = File.join(dir, "auth.sql")

      status, _stdout, stderr = run_cli("generate", "--cwd", dir, "--config", config_path, "--dialect", "sqlite", "--output", output)

      assert_equal 0, status, stderr
      sql = File.read(output)
      refute_includes sql, 'CREATE TABLE IF NOT EXISTS "audit_logs"'
      refute_includes sql, "index_audit_logs_on_user_id"
    end
  end

  def test_generate_includes_database_rate_limit_table
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir, rate_limit: {enabled: true, storage: "database"})
      output = File.join(dir, "auth.sql")

      status, _stdout, stderr = run_cli("generate", "--cwd", dir, "--config", config_path, "--dialect", "sqlite", "--output", output)

      assert_equal 0, status, stderr
      assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "rate_limits"'
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

        status, _stdout, stderr = run_cli("generate", "--cwd", dir, "--config", config_path, "--dialect", dialect.to_s, "--output", output)
        assert_equal 0, status, "#{dialect}: #{stderr}"
        assert_includes File.read(output), "CREATE TABLE"
        assert_includes File.read(output), quoted_users

        status, stdout, stderr = run_cli("migrate", "status", "--cwd", dir, "--config", config_path)
        assert_equal 0, status, "#{dialect}: #{stderr}"
        assert_includes stdout, "create table users"
      end
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

      status, _stdout, stderr = run_cli("generate", "--cwd", dir, "--config", config_path, "--dialect", "sqlite", "--output", output)

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

      status, _stdout, stderr = run_cli("generate", "--cwd", dir, "--config", sqlite_config, "--dialect", "sqlite", "--output", sqlite_out)
      assert_equal 0, status, stderr
      status, _stdout, stderr = run_cli("generate", "--cwd", dir, "--config", postgres_config, "--dialect", "postgres", "--output", postgres_out)
      assert_equal 0, status, stderr

      assert_includes File.read(sqlite_out), '"metadata" text'
      assert_includes File.read(postgres_out), '"metadata" jsonb'
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

      status, stdout, stderr = run_cli("generate", "--cwd", dir, "--config", config_path, "--dialect", "postgres", "--output", output)

      assert_equal 1, status
      assert_empty stdout
      assert_includes stderr, "Unsupported field type: object"
      refute File.exist?(output)
    end
  end

  def test_secret_generates_unique_values
    _status, first_stdout, _stderr = run_cli("secret")
    _status, second_stdout, _stderr = run_cli("secret")

    refute_equal first_stdout, second_stdout
  end
end
