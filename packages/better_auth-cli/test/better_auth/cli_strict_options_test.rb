# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../../better_auth/lib", __dir__)

require "better_auth/cli"
require "better_auth/cli/errors"
require "minitest/autorun"
require_relative "../support/cli_helpers"

class BetterAuthCLIStrictOptionsTest < Minitest::Test
  include BetterAuthCLITestHelpers

  def test_doctor_with_no_flags_requires_cwd
    status, _stdout, stderr = run_cli_strict("doctor")

    assert_equal 1, status
    assert_includes stderr, "--cwd"
  end

  def test_doctor_with_cwd_but_no_config_requires_config_or_discover
    Dir.mktmpdir("better-auth-cli-strict") do |dir|
      status, _stdout, stderr = run_cli_strict("doctor", "--cwd", dir)

      assert_equal 1, status
      assert_includes stderr, "--config"
      assert_includes stderr, "--discover-config"
    end
  end

  def test_generate_without_dialect_requires_dialect_flag
    Dir.mktmpdir("better-auth-cli-strict") do |dir|
      config_path = write_hash_config(dir, secret: SECRET, database: :memory)
      output = File.join(dir, "auth.sql")

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

  def test_generate_without_cwd_requires_cwd_flag
    status, _stdout, stderr = run_cli_strict("generate", "--dialect", "sqlite", "--output", "auth.sql")

    assert_equal 1, status
    assert_includes stderr, "--cwd"
  end

  def test_migrate_without_cwd_requires_cwd_flag
    status, _stdout, stderr = run_cli_strict("migrate", "--yes")

    assert_equal 1, status
    assert_includes stderr, "--cwd"
  end

  def test_missing_option_errors_are_multiline_with_example
    expected = BetterAuth::CLI::Errors.missing_option(
      "doctor",
      "--cwd",
      [
        "Example: better-auth doctor --cwd . --config config/better_auth.rb"
      ]
    )

    status, _stdout, stderr = run_cli_strict("doctor")

    assert_equal 1, status
    assert_includes stderr, "Example:"
    assert_equal expected, stderr.strip
  end

  def test_discover_config_finds_config_under_cwd
    Dir.mktmpdir("better-auth-cli-strict") do |dir|
      write_sqlite_project_config(dir, secret: HARDENED_SECRET, base_url: "https://example.test")

      status, stdout, stderr = run_cli_strict("doctor", "--cwd", dir, "--discover-config")

      assert_equal 0, status, stderr
      assert_includes stdout, "OK config loaded"
    end
  end

  def test_info_requires_cwd
    status, _stdout, stderr = run_cli_strict("info", "--json")

    assert_equal 1, status
    assert_includes stderr, "--cwd"
  end
end
