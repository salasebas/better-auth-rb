# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliConfigResolutionTest < BetterAuthCLITestCase
  def test_config_eval_error_returns_status_without_backtrace
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_config(dir, "raise RuntimeError, \"boom\"")

      status, stdout, stderr = run_cli("doctor", "--cwd", dir, "--config", config_path)

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

      status, _stdout, stderr = run_cli("doctor", "--cwd", dir, "--config", configure_path)
      assert_equal 0, status, stderr

      status, stdout, stderr = run_cli("doctor", "--cwd", dir, "--config", invalid_path)

      assert_equal 1, status
      assert_empty stdout
      assert_includes stderr, "Hash, BetterAuth::Configuration, or BetterAuth::Auth"
    end
  end

  def test_generate_discovers_config_under_cwd
    Dir.mktmpdir("better-auth-cli") do |dir|
      write_sqlite_project_config(dir)
      output = File.join(dir, "db", "auth.sql")

      status, stdout, stderr = run_cli("generate", "--cwd", dir, "--discover-config", "--dialect", "sqlite", "--output", "db/auth.sql")

      assert_equal 0, status, stderr
      assert_includes stdout, "generated #{output}"
      assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "users"'
    end
  end

  def test_migrate_discovers_config_under_cwd
    Dir.mktmpdir("better-auth-cli") do |dir|
      write_sqlite_project_config(dir)

      status, stdout, stderr = run_cli("migrate", "--cwd", dir, "--discover-config", "--yes")

      assert_equal 0, status, stderr
      assert_includes stdout, "migration completed successfully."
      assert_includes sqlite_tables(dir), "users"
    end
  end

  def test_migrate_status_discovers_config_under_cwd
    Dir.mktmpdir("better-auth-cli") do |dir|
      write_sqlite_project_config(dir)

      status, stdout, stderr = run_cli("migrate", "status", "--cwd", dir, "--discover-config")

      assert_equal 0, status, stderr
      assert_includes stdout, "create table users"
    end
  end

  def test_doctor_discovers_config_under_cwd
    Dir.mktmpdir("better-auth-cli") do |dir|
      write_sqlite_project_config(
        dir,
        secret: BetterAuth::Configuration::DEFAULT_SECRET,
        base_url: "http://example.test"
      )

      status, stdout, stderr = run_cli("doctor", "--cwd", dir, "--discover-config")

      assert_equal 1, status
      assert_includes stderr, "ERROR secret uses the default development value"
      assert_includes stdout, "WARN base_url is not HTTPS"
    end
  end

  def test_explicit_config_wins_over_discovered_config
    Dir.mktmpdir("better-auth-cli") do |dir|
      write_sqlite_project_config(dir, secret: "short")
      explicit_config = write_hash_config(
        dir,
        secret: HARDENED_SECRET,
        database: :memory,
        filename: "explicit.rb"
      )

      status, stdout, stderr = run_cli(
        "doctor",
        "--cwd",
        dir,
        "--config",
        explicit_config
      )

      assert_equal 0, status, stderr
      assert_includes stdout, "OK config loaded"
      refute_includes stderr, "at least 32 characters"
    end
  end

  def test_relative_config_resolves_against_cwd
    Dir.mktmpdir("better-auth-cli") do |dir|
      write_sqlite_project_config(dir)
      output = File.join(dir, "auth.sql")

      status, _stdout, stderr = run_cli(
        "generate",
        "--cwd",
        dir,
        "--config",
        "config/better_auth.rb",
        "--dialect",
        "sqlite",
        "--output",
        output
      )

      assert_equal 0, status, stderr
      assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "users"'
    end
  end

  def test_relative_output_resolves_against_cwd
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir)
      output = File.join(dir, "nested", "auth.sql")

      status, stdout, stderr = run_cli(
        "generate",
        "--cwd",
        dir,
        "--config",
        config_path,
        "--dialect",
        "sqlite",
        "--output",
        "nested/auth.sql"
      )

      assert_equal 0, status, stderr
      assert_includes stdout, "generated #{output}"
      assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "users"'
    end
  end

  def test_absolute_output_stays_absolute
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir)
      output_dir = Dir.mktmpdir("better-auth-cli-output")
      output = File.join(output_dir, "absolute.sql")

      status, stdout, stderr = run_cli(
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

      assert_equal 0, status, stderr
      assert_includes stdout, "generated #{output}"
      assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "users"'
    end
  end

  def test_missing_cwd_directory_returns_error
    status, _stdout, stderr = run_cli("doctor", "--cwd", "/tmp/better-auth-cli-missing-cwd-#{Process.pid}")

    assert_equal 1, status
    assert_includes stderr, "--cwd is not a directory"
  end

  def test_missing_discovered_config_lists_searched_paths
    Dir.mktmpdir("better-auth-cli") do |dir|
      status, _stdout, stderr = run_cli("doctor", "--cwd", dir, "--discover-config")

      assert_equal 1, status
      assert_includes stderr, "No Better Auth config found"
      assert_includes stderr, "config/better_auth.rb"
      assert_includes stderr, "config/auth.rb"
      assert_includes stderr, "Pass --config PATH"
    end
  end

  def test_config_discovery_order_is_deterministic
    Dir.mktmpdir("better-auth-cli") do |dir|
      write_config(dir, "42", filename: "config/auth.rb")
      write_sqlite_project_config(dir, secret: HARDENED_SECRET, base_url: "https://example.test")

      status, _stdout, stderr = run_cli("migrate", "--cwd", dir, "--discover-config", "--yes")
      assert_equal 0, status, stderr

      status, stdout, stderr = run_cli("doctor", "--cwd", dir, "--discover-config")

      assert_equal 0, status, stderr
      assert_includes stdout, "OK database schema is up to date"
    end
  end

  def test_missing_discovered_config_does_not_expose_config_contents
    Dir.mktmpdir("better-auth-cli") do |dir|
      write_config(dir, "secret: 'should-not-appear'", filename: "hidden/auth.rb")

      status, _stdout, stderr = run_cli("doctor", "--cwd", dir, "--discover-config")

      assert_equal 1, status
      assert_includes stderr, "No Better Auth config found"
      refute_includes stderr, "should-not-appear"
    end
  end
end
