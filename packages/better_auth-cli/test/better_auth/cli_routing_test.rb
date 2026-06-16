# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliRoutingTest < BetterAuthCLITestCase
  def test_missing_config_file_returns_error
    Dir.mktmpdir("better-auth-cli") do |dir|
      status, _stdout, stderr = run_cli("doctor", "--cwd", dir, "--config", File.join(dir, "missing.rb"))

      assert_equal 1, status
      assert_includes stderr, "Config file not found"
    end
  end

  def test_invalid_config_return_reports_allowed_types
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_config(dir, "42")

      status, _stdout, stderr = run_cli("doctor", "--cwd", dir, "--config", config_path)

      assert_equal 1, status
      assert_includes stderr, "Hash, BetterAuth::Configuration, or BetterAuth::Auth"
    end
  end

  def test_help_with_no_args_lists_all_commands
    status, stdout, stderr = run_cli

    assert_equal 0, status, stderr
    assert_usage_lists_commands(stdout)
  end

  def test_help_flag_variants_list_all_commands
    %w[help --help -h].each do |flag|
      status, stdout, stderr = run_cli(flag)

      assert_equal 0, status, "#{flag}: #{stderr}"
      assert_usage_lists_commands(stdout)
    end
  end

  def test_unknown_command_returns_error
    status, stdout, stderr = run_cli("wat")

    assert_equal 1, status
    assert_empty stdout
    assert_includes stderr, "Unknown command: wat"
  end

  def test_better_auth_executable_help_lists_commands
    stdout, stderr, status = run_better_auth_executable("--help")

    assert status.success?, stderr
    assert_usage_lists_commands(stdout)
  end

  def test_better_auth_executable_unknown_command_returns_error
    stdout, stderr, status = run_better_auth_executable("wat")

    assert_equal false, status.success?
    assert_empty stdout
    assert_includes stderr, "Unknown command: wat"
  end

  def test_missing_required_options_return_errors
    status, _stdout, stderr = run_cli_strict("generate", "--config", "config.rb")
    assert_equal 1, status
    assert_includes stderr, "--cwd"

    status, _stdout, stderr = run_cli_strict("migrate")
    assert_equal 1, status
    assert_includes stderr, "--cwd"

    status, _stdout, stderr = run_cli_strict("doctor")
    assert_equal 1, status
    assert_includes stderr, "--cwd"
  end

  def test_invalid_option_returns_error_status
    status, _stdout, stderr = run_cli("generate", "--cwd", Dir.pwd, "--config", "config/better_auth.rb", "--dialect", "sqlite", "--output", "out.sql", "--bogus")

    assert_equal 1, status
    assert_includes stderr, "invalid option: --bogus"
  end

  def test_missing_option_argument_returns_error_status
    status, _stdout, stderr = run_cli("generate", "--cwd", Dir.pwd, "--config")

    assert_equal 1, status
    assert_includes stderr, "missing argument: --config"
  end

  def test_better_auth_executable_is_packaged
    spec = Gem::Specification.load(File.expand_path("../../better_auth-cli.gemspec", __dir__))

    assert_includes spec.executables, "better-auth"
    refute_includes spec.executables, "openauth"
  end

  private

  def assert_usage_lists_commands(usage)
    assert_includes usage, "better-auth init"
    assert_includes usage, "better-auth generate"
    assert_includes usage, "better-auth migrate"
    assert_includes usage, "migrate status"
    assert_includes usage, "better-auth doctor"
    assert_includes usage, "better-auth info"
    assert_includes usage, "better-auth secret"
    assert_includes usage, "mongo indexes"
    assert_includes usage, "better-auth upgrade"
    assert_includes usage, "config/better_auth.rb"
    assert_includes usage, "--cwd"
    assert_includes usage, "--discover-config"
  end
end
