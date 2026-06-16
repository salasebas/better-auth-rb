# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliSecretParityTest < BetterAuthCLITestCase
  def test_secret_does_not_require_cwd
    status, stdout, stderr = run_cli_strict("secret")
    assert_equal 0, status, stderr
    assert_match(/\ABETTER_AUTH_SECRET=/, stdout)
  end

  def test_secret_raw_strict_mode
    status, stdout, stderr = run_cli_strict("secret", "--raw")
    assert_equal 0, status, stderr
    assert_match(/\A[0-9a-f]{64}\n\z/, stdout)
  end

  def test_secret_output_never_includes_stderr
    status, stdout, stderr = run_cli("secret")
    assert_equal 0, status
    assert_empty stderr
    refute_empty stdout
  end
end
