# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliInitEnvTest < BetterAuthCLITestCase
  def test_init_without_write_env_example_does_not_create_env_example
    Dir.mktmpdir("better-auth-cli-init-env") do |dir|
      run_init_cli("--cwd", dir, "--framework", "rack")

      refute File.exist?(File.join(dir, ".env.example"))
      refute File.exist?(File.join(dir, ".env"))
    end
  end

  def test_init_write_env_example_creates_env_example_not_env
    Dir.mktmpdir("better-auth-cli-init-env") do |dir|
      run_init_cli("--cwd", dir, "--framework", "rack", "--write-env-example")

      assert File.exist?(File.join(dir, ".env.example"))
      refute File.exist?(File.join(dir, ".env"))
      content = File.read(File.join(dir, ".env.example"))
      assert_includes content, "BETTER_AUTH_SECRET="
      assert_includes content, "BETTER_AUTH_URL="
    end
  end

  def test_init_write_env_example_skips_existing_file_without_force
    Dir.mktmpdir("better-auth-cli-init-env") do |dir|
      File.write(File.join(dir, ".env.example"), "existing=true\n")

      run_init_cli("--cwd", dir, "--framework", "rack", "--write-env-example")

      assert_equal "existing=true\n", File.read(File.join(dir, ".env.example"))
    end
  end

  def test_init_env_example_template_does_not_include_secrets
    Dir.mktmpdir("better-auth-cli-init-env") do |dir|
      _status, stdout, _stderr = run_init_cli("--cwd", dir, "--framework", "rack", "--write-env-example")

      assert_includes stdout, "create .env.example"
      refute_includes File.read(File.join(dir, ".env.example")), "change-me"
    end
  end
end
