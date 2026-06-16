# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliSecretTest < BetterAuthCLITestCase
  def test_secret_prints_env_assignment_and_exits_zero
    status, stdout, stderr = run_cli("secret")

    assert_equal 0, status, stderr
    assert_match(/\ABETTER_AUTH_SECRET=[0-9a-f]{64}\n\z/, stdout)
  end

  def test_secret_raw_prints_only_hex_secret
    status, stdout, stderr = run_cli("secret", "--raw")

    assert_equal 0, status, stderr
    assert_match(/\A[0-9a-f]{64}\n\z/, stdout)
    refute_includes stdout, "BETTER_AUTH_SECRET="
  end

  def test_better_auth_executable_secret_succeeds
    stdout, stderr, status = run_better_auth_executable("secret")

    assert status.success?, stderr
    assert_match(/\ABETTER_AUTH_SECRET=[0-9a-f]{64}\n\z/, stdout)
  end
end
