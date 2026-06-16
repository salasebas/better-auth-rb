# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliInitPluginsTest < BetterAuthCLITestCase
  def test_plugin_flag_adds_placeholder_to_config
    Dir.mktmpdir("better-auth-cli-init-plugins") do |dir|
      run_init_cli("--cwd", dir, "--framework", "rack", "--plugin", "two_factor")
      content = File.read(File.join(dir, "config", "better_auth.rb"))

      assert_includes content, "plugin: two_factor"
    end
  end

  def test_multiple_plugin_flags_all_appear
    Dir.mktmpdir("better-auth-cli-init-plugins") do |dir|
      run_init_cli(
        "--cwd", dir,
        "--framework", "rack",
        "--plugin", "two_factor",
        "--plugin", "username"
      )
      content = File.read(File.join(dir, "config", "better_auth.rb"))

      assert_includes content, "plugin: two_factor"
      assert_includes content, "plugin: username"
    end
  end

  def test_unknown_plugin_returns_error
    Dir.mktmpdir("better-auth-cli-init-plugins") do |dir|
      status, _stdout, stderr = run_init_cli("--cwd", dir, "--framework", "rack", "--plugin", "not_a_plugin")

      assert_equal 1, status
      assert_includes stderr, "Unsupported init plugin"
    end
  end

  %w[organization email_otp magic_link bearer jwt anonymous].each do |plugin|
    define_method("test_plugin_#{plugin}_is_supported") do
      Dir.mktmpdir("better-auth-cli-init-plugin-#{plugin}") do |dir|
        status, _stdout, stderr = run_init_cli("--cwd", dir, "--framework", "rack", "--plugin", plugin)
        assert_equal 0, status, stderr
        assert_includes File.read(File.join(dir, "config", "better_auth.rb")), "plugin: #{plugin}"
      end
    end
  end

  def test_plugins_default_to_empty_array
    Dir.mktmpdir("better-auth-cli-init-plugins") do |dir|
      run_init_cli("--cwd", dir, "--framework", "rack")
      content = File.read(File.join(dir, "config", "better_auth.rb"))

      assert_includes content, "plugins: []"
    end
  end
end
