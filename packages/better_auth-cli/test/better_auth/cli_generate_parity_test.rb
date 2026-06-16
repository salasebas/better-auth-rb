# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliGenerateParityTest < BetterAuthCLITestCase
  DIALECTS = {
    sqlite: '"users"',
    postgres: '"users"',
    mysql: "`users`",
    mssql: "[users]"
  }.freeze

  DIALECTS.each do |dialect, quoted_users|
    define_method("test_generate_#{dialect}_writes_quoted_table_names") do
      Dir.mktmpdir("better-auth-cli-generate-#{dialect}") do |dir|
        config_path = write_fake_sql_config(dir, dialect: dialect)
        output = File.join(dir, "#{dialect}.sql")

        status, _stdout, stderr = run_cli(
          "generate",
          "--cwd", dir,
          "--config", config_path,
          "--dialect", dialect.to_s,
          "--output", output
        )

        assert_equal 0, status, stderr
        assert_includes File.read(output), quoted_users
      end
    end

    define_method("test_migrate_status_#{dialect}_lists_pending_users_table") do
      Dir.mktmpdir("better-auth-cli-migrate-#{dialect}") do |dir|
        config_path = write_fake_sql_config(dir, dialect: dialect)

        status, stdout, stderr = run_cli("migrate", "status", "--cwd", dir, "--config", config_path)

        assert_equal 0, status, stderr
        assert_includes stdout, "create table users"
      end
    end
  end

  def test_generate_strict_missing_output
    status, _stdout, stderr = run_cli_strict(
      "generate",
      "--cwd", Dir.pwd,
      "--config", "config/better_auth.rb",
      "--dialect", "sqlite"
    )
    assert_equal 1, status
    assert_includes stderr, "output"
  end

  def test_generate_strict_missing_config_and_discover
    status, _stdout, stderr = run_cli_strict("generate", "--cwd", Dir.pwd, "--dialect", "sqlite", "--output", "out.sql")
    assert_equal 1, status
    assert_includes stderr, "--config"
  end

  def test_generate_discover_config_writes_sql
    Dir.mktmpdir("better-auth-cli-generate-discover") do |dir|
      write_sqlite_project_config(dir)
      output = File.join(dir, "db", "auth.sql")

      status, stdout, stderr = run_cli(
        "generate",
        "--cwd", dir,
        "--discover-config",
        "--dialect", "sqlite",
        "--output", "db/auth.sql"
      )

      assert_equal 0, status, stderr
      assert_includes stdout, "generated #{output}"
    end
  end

  %w[sqlite postgres mysql mssql].each do |dialect|
    define_method("test_generate_strict_missing_dialect_for_#{dialect}_config") do
      Dir.mktmpdir("better-auth-cli-strict-#{dialect}") do |dir|
        config_path = write_fake_sql_config(dir, dialect: dialect)
        output = File.join(dir, "out.sql")

        status, _stdout, stderr = run_cli_strict(
          "generate",
          "--cwd", dir,
          "--config", config_path,
          "--output", output
        )

        assert_equal 1, status
        assert_includes stderr, "--dialect"
      end
    end
  end
end
