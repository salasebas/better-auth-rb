# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliUpgradeTest < BetterAuthCLITestCase
  def test_upgrade_without_cwd_errors
    status, _stdout, stderr = run_cli_strict("upgrade")
    assert_equal 1, status
    assert_includes stderr, "--cwd"
  end

  def test_upgrade_without_gemfile_errors
    Dir.mktmpdir("better-auth-cli-upgrade") do |dir|
      status, _stdout, stderr = run_cli("upgrade", "--cwd", dir)
      assert_equal 1, status
      assert_includes stderr, "No Gemfile found"
    end
  end

  def test_upgrade_dry_run_lists_gems_and_bundle_command
    Dir.mktmpdir("better-auth-cli-upgrade") do |dir|
      File.write(File.join(dir, "Gemfile"), <<~GEM)
        source "https://rubygems.org"
        gem "better_auth"
        gem "better_auth-rails"
      GEM

      status, stdout, stderr = run_cli("upgrade", "--cwd", dir)

      assert_equal 0, status, stderr
      assert_includes stdout, "better_auth"
      assert_includes stdout, "better_auth-rails"
      assert_includes stdout, "bundle update"
    end
  end

  def test_upgrade_yes_prints_bundle_update_command
    Dir.mktmpdir("better-auth-cli-upgrade") do |dir|
      File.write(File.join(dir, "Gemfile"), 'gem "better_auth"')

      status, stdout, stderr = run_cli("upgrade", "--cwd", dir, "--yes")

      assert_equal 0, status, stderr
      assert_includes stdout, "bundle update better_auth"
    end
  end
end
