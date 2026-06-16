# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliDoctorTest < BetterAuthCLITestCase
  def test_doctor_reports_insecure_secret_and_pending_migrations
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(
        dir,
        secret: BetterAuth::Configuration::DEFAULT_SECRET,
        base_url: "http://example.test"
      )

      status, stdout, stderr = run_cli("doctor", "--cwd", dir, "--config", config_path)

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
      status, _stdout, stderr = run_cli("migrate", "--cwd", dir, "--config", config_path, "--yes")
      assert_equal 0, status, stderr

      status, stdout, stderr = run_cli("doctor", "--cwd", dir, "--config", config_path)

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

      status, stdout, stderr = run_cli("doctor", "--cwd", dir, "--config", config_path)

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

      status, stdout, stderr = run_cli("doctor", "--cwd", dir, "--config", config_path)

      assert_equal 0, status, stderr
      assert_includes stdout, "OK rate_limit storage is secondary-storage"
      refute_includes stdout, "rate_limit uses memory storage"
    end
  end

  def test_doctor_reports_short_and_low_entropy_secrets
    Dir.mktmpdir("better-auth-cli") do |dir|
      short_config = write_sqlite_config(dir, secret: "short")
      status, _stdout, stderr = run_cli("doctor", "--cwd", dir, "--config", short_config)
      assert_equal 1, status
      assert_includes stderr, "at least 32 characters"

      low_entropy_config = write_sqlite_config(dir, secret: "a" * 32)
      status, _stdout, stderr = run_cli("doctor", "--cwd", dir, "--config", low_entropy_config)
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
      status, stdout, stderr = run_cli("doctor", "--cwd", dir, "--config", missing_base_url)
      assert_equal 0, status, stderr
      assert_includes stdout, "WARN base_url is not configured"

      secondary_config = write_hash_config(
        dir,
        secret: HARDENED_SECRET,
        database: :memory,
        rate_limit: {enabled: true, storage: "secondary-storage"},
        filename: "secondary_rate_limit.rb"
      )
      status, stdout, stderr = run_cli("doctor", "--cwd", dir, "--config", secondary_config)
      assert_equal 0, status, stderr
      assert_includes stdout, "OK rate_limit storage is secondary-storage"
    end
  end

  def test_doctor_skips_schema_drift_for_memory_adapter
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_hash_config(dir, secret: HARDENED_SECRET, database: :memory)

      status, stdout, stderr = run_cli("doctor", "--cwd", dir, "--config", config_path)

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
      status, stdout, stderr = run_cli("doctor", "--cwd", dir, "--config", config_path)

      assert_equal 0, status, stderr
      assert_includes stdout, "WARN database has pending Better Auth migrations"
      assert stdout.lines.any? { |line| line.include?("users.email") }
    end
  end

  def test_doctor_json_returns_doctor_payload_and_preserves_exit_status
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(
        dir,
        secret: BetterAuth::Configuration::DEFAULT_SECRET,
        base_url: "http://example.test"
      )

      status, stdout, stderr = run_cli("doctor", "--cwd", dir, "--json", "--config", config_path)

      assert_equal 1, status
      assert_empty stderr
      payload = JSON.parse(stdout)
      assert_equal false, payload["success"]
      assert payload["errors"].any? { |message| message.include?("default development value") }
      assert payload["warnings"].any? { |message| message.include?("HTTPS") }
    end
  end

  def test_doctor_json_success_matches_text_doctor_exit_status
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(
        dir,
        secret: HARDENED_SECRET,
        base_url: "https://example.test",
        rate_limit: {enabled: true, storage: "database"}
      )
      status, _stdout, stderr = run_cli("migrate", "--cwd", dir, "--config", config_path, "--yes")
      assert_equal 0, status, stderr

      status, stdout, stderr = run_cli("doctor", "--cwd", dir, "--json", "--config", config_path)

      assert_equal 0, status, stderr
      payload = JSON.parse(stdout)
      assert_equal true, payload["success"]
      assert_empty payload["errors"]
    end
  end
end
