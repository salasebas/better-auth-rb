# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliRoutingParityTest < BetterAuthCLITestCase
  COMMANDS = %w[init generate migrate doctor info secret upgrade mongo].freeze

  COMMANDS.each do |command|
    define_method("test_help_lists_#{command}_command") do
      status, stdout, stderr = run_cli("help")
      assert_equal 0, status, stderr
      assert_includes stdout, command
    end
  end

  def test_init_listed_in_help_with_framework_flags
    status, stdout, stderr = run_cli("help")
    assert_equal 0, status, stderr
    assert_includes stdout, "--framework"
    assert_includes stdout, "--detect-framework"
  end

  def test_upgrade_listed_in_help_with_cwd
    status, stdout, stderr = run_cli("help")
    assert_equal 0, status, stderr
    assert_includes stdout, "better-auth upgrade"
    assert_includes stdout, "--yes"
  end

  %w[generate migrate doctor mongo].each do |command|
    define_method("test_#{command}_help_mentions_discover_config") do
      status, stdout, stderr = run_cli("help")
      assert_equal 0, status, stderr
      assert_includes stdout, "--discover-config"
    end
  end
end
