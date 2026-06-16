# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliStrictOptionsParityTest < BetterAuthCLITestCase
  COMMANDS = {
    "generate" => ["--dialect", "sqlite", "--output", "out.sql"],
    "migrate" => ["--yes"],
    "doctor" => [],
    "info" => ["--json"],
    "mongo indexes" => []
  }.freeze

  COMMANDS.each do |command, extra_args|
    define_method("test_#{command.tr(" ", "_")}_strict_requires_cwd") do
      argv = command.split + extra_args
      status, _stdout, stderr = run_cli_strict(*argv)
      assert_equal 1, status
      assert_includes stderr, "--cwd"
    end
  end

  def test_upgrade_strict_requires_cwd
    status, _stdout, stderr = run_cli_strict("upgrade")
    assert_equal 1, status
    assert_includes stderr, "--cwd"
  end

  def test_init_strict_requires_cwd
    status, _stdout, stderr = run_cli_strict("init", "--framework", "rack")
    assert_equal 1, status
    assert_includes stderr, "--cwd"
  end
end
