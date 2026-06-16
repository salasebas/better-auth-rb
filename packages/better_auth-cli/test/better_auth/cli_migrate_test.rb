# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliMigrateTest < BetterAuthCLITestCase
  def test_migrate_requires_yes
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir)

      status, _stdout, stderr = run_cli("migrate", "--cwd", dir, "--config", config_path)

      assert_equal 1, status
      assert_includes stderr, "Pass --yes to apply migrations."
    end
  end

  def test_migrate_applies_pending_schema_and_repeated_migrate_reports_no_changes
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir)

      status, stdout, stderr = run_cli("migrate", "--cwd", dir, "--config", config_path, "--yes")
      assert_equal 0, status, stderr
      assert_includes stdout, "migration completed successfully."
      assert_includes sqlite_tables(dir), "users"

      status, stdout, stderr = run_cli("migrate", "--cwd", dir, "--config", config_path, "--yes")
      assert_equal 0, status, stderr
      assert_includes stdout, "No migrations needed."
    end
  end

  def test_migrate_status_lists_pending_schema_before_migration_and_no_changes_after
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir)

      status, stdout, stderr = run_cli("migrate", "status", "--cwd", dir, "--config", config_path)
      assert_equal 0, status, stderr
      assert_includes stdout, "create table users"

      status, _stdout, stderr = run_cli("migrate", "--cwd", dir, "--config", config_path, "--yes")
      assert_equal 0, status, stderr

      status, stdout, stderr = run_cli("migrate", "status", "--cwd", dir, "--config", config_path)
      assert_equal 0, status, stderr
      assert_includes stdout, "No migrations needed."
    end
  end

  def test_migrate_reports_unsupported_adapter
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_hash_config(dir, secret: SECRET, database: :memory)

      status, _stdout, stderr = run_cli("migrate", "--cwd", dir, "--config", config_path, "--yes")

      assert_equal 1, status
      assert_includes stderr, "SQL adapters"
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

      status, stdout, stderr = run_cli("migrate", "status", "--cwd", dir, "--config", config_path)

      assert_equal 0, status, stderr
      assert_includes stdout, "create table audit_logs"
      assert_includes stdout, "create index index_audit_logs_on_action"
    end
  end

  def test_migrate_status_reports_new_plugin_table_after_core_migration
    Dir.mktmpdir("better-auth-cli") do |dir|
      base_config = write_sqlite_config(dir)

      status, _stdout, stderr = run_cli("migrate", "--cwd", dir, "--config", base_config, "--yes")
      assert_equal 0, status, stderr

      plugin_config = write_sqlite_config(dir, plugins_source: "[BetterAuth::Plugins.two_factor]")
      status, stdout, stderr = run_cli("migrate", "status", "--cwd", dir, "--config", plugin_config)

      assert_equal 0, status, stderr
      assert_includes stdout, "create table two_factors"
    end
  end

  def test_migrate_after_cli_migrate_supports_email_sign_up
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir)

      status, _stdout, stderr = run_cli("migrate", "--cwd", dir, "--config", config_path, "--yes")
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

      status, _stdout, stderr = run_cli("migrate", "--cwd", dir, "--config", config_path, "--yes")
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
      status, _stdout, stderr = run_cli("migrate", "--cwd", dir, "--config", config_path, "--yes")
      assert_equal 0, status, stderr

      extended_config = write_sqlite_config(
        dir,
        user_options_source: "{additional_fields: {role: {type: \"string\", required: false}}}"
      )
      status, stdout, stderr = run_cli("migrate", "status", "--cwd", dir, "--config", extended_config)

      assert_equal 0, status, stderr
      assert_includes stdout, "add role to users"
    end
  end

  def test_migrate_status_reports_missing_index_for_indexed_additional_field
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir)
      status, _stdout, stderr = run_cli("migrate", "--cwd", dir, "--config", config_path, "--yes")
      assert_equal 0, status, stderr

      extended_config = write_sqlite_config(
        dir,
        user_options_source: "{additional_fields: {badge: {type: \"string\", required: false, index: true}}}"
      )
      status, stdout, stderr = run_cli("migrate", "status", "--cwd", dir, "--config", extended_config)

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
      status, stdout, stderr = run_cli("migrate", "status", "--cwd", dir, "--config", config_path)

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

      status, stdout, stderr = run_cli("migrate", "status", "--cwd", dir, "--config", config_path)
      assert_equal 0, status, stderr
      pending_lines = stdout.lines.map(&:strip).reject(&:empty?)
      assert_equal pending_lines, pending_lines.uniq

      status, _stdout, stderr = run_cli("migrate", "--cwd", dir, "--config", config_path, "--yes")
      assert_equal 0, status, stderr

      status, stdout, stderr = run_cli("migrate", "status", "--cwd", dir, "--config", config_path)
      assert_equal 0, status, stderr
      assert_includes stdout, "No migrations needed."
    end
  end
end
