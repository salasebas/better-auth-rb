# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliMigrateParityTest < BetterAuthCLITestCase
  def test_migrate_repeat_reports_no_changes
    skip_db_integration_unless_enabled!

    Dir.mktmpdir("better-auth-cli-migrate-repeat") do |dir|
      config_path = write_sqlite_config(dir)

      status, _stdout, stderr = run_cli("migrate", "--cwd", dir, "--config", config_path, "--yes")
      assert_equal 0, status, stderr

      status, stdout, stderr = run_cli("migrate", "--cwd", dir, "--config", config_path, "--yes")
      assert_equal 0, status, stderr
      assert_includes stdout, "No migrations needed"
    end
  end

  def test_migrate_status_after_migrate_reports_no_pending
    skip_db_integration_unless_enabled!

    Dir.mktmpdir("better-auth-cli-migrate-status") do |dir|
      config_path = write_sqlite_config(dir)

      status, _stdout, stderr = run_cli("migrate", "--cwd", dir, "--config", config_path, "--yes")
      assert_equal 0, status, stderr

      status, stdout, stderr = run_cli("migrate", "status", "--cwd", dir, "--config", config_path)
      assert_equal 0, status, stderr
      assert_includes stdout, "No migrations needed"
    end
  end
end
