# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliConfigParityTest < BetterAuthCLITestCase
  def test_discover_config_requires_explicit_flag_in_strict_mode
    Dir.mktmpdir("better-auth-cli-config") do |dir|
      write_sqlite_project_config(dir)

      status, _stdout, stderr = run_cli_strict("doctor", "--cwd", dir)

      assert_equal 1, status
      assert_includes stderr, "--discover-config"
    end
  end

  def test_migrate_strict_requires_yes_and_cwd
    status, _stdout, stderr = run_cli_strict("migrate")
    assert_equal 1, status
    assert_includes stderr, "--cwd"
  end

  def test_migrate_with_cwd_config_but_no_yes_errors
    Dir.mktmpdir("better-auth-cli-config") do |dir|
      config_path = write_sqlite_project_config(dir)

      status, _stdout, stderr = run_cli_strict("migrate", "--cwd", dir, "--config", config_path)

      assert_equal 1, status
      assert_includes stderr, "--yes"
    end
  end

  def test_relative_config_against_cwd_resolves_in_strict_mode
    Dir.mktmpdir("better-auth-cli-config") do |dir|
      write_sqlite_project_config(dir, secret: HARDENED_SECRET, base_url: "https://example.test")

      status, stdout, stderr = run_cli_strict(
        "doctor",
        "--cwd", dir,
        "--config", "config/better_auth.rb"
      )

      assert_equal 0, status, stderr
      assert_includes stdout, "OK config loaded"
    end
  end

  %w[generate migrate doctor].each do |command|
    define_method("test_#{command}_strict_missing_cwd") do
      status, _stdout, stderr = run_cli_strict(command)
      assert_equal 1, status
      assert_includes stderr, "--cwd"
    end
  end
end
