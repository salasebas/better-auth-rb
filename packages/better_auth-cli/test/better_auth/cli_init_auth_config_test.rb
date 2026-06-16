# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliInitAuthConfigTest < BetterAuthCLITestCase
  def test_rack_scaffold_includes_email_and_password
    Dir.mktmpdir("better-auth-cli-init-auth") do |dir|
      run_init_cli("--cwd", dir, "--framework", "rack")
      content = File.read(File.join(dir, "config", "better_auth.rb"))

      assert_includes content, "email_and_password: {enabled: true}"
    end
  end

  def test_rack_scaffold_uses_env_fetch_for_secret_not_hardcoded
    Dir.mktmpdir("better-auth-cli-init-auth") do |dir|
      run_init_cli("--cwd", dir, "--framework", "rack")
      content = File.read(File.join(dir, "config", "better_auth.rb"))

      assert_includes content, 'secret: ENV.fetch("BETTER_AUTH_SECRET")'
      refute_match(/secret:\s*["'][^"']{8,}["']/, content)
    end
  end

  def test_rack_scaffold_uses_env_fetch_for_base_url
    Dir.mktmpdir("better-auth-cli-init-auth") do |dir|
      run_init_cli("--cwd", dir, "--framework", "rack")
      content = File.read(File.join(dir, "config", "better_auth.rb"))

      assert_includes content, 'base_url: ENV.fetch("BETTER_AUTH_URL")'
    end
  end

  def test_rack_scaffold_includes_secret_comment_not_auto_generated_value
    Dir.mktmpdir("better-auth-cli-init-auth") do |dir|
      run_init_cli("--cwd", dir, "--framework", "rack")
      content = File.read(File.join(dir, "config", "better_auth.rb"))

      assert_includes content, "never commit secrets"
    end
  end
end
