# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliInitParityTest < BetterAuthCLITestCase
  def test_init_rack_creates_migration_directory
    Dir.mktmpdir("better-auth-cli-init-parity") do |dir|
      run_init_cli("--cwd", dir, "--framework", "rack")
      assert File.directory?(File.join(dir, "db", "better_auth", "migrate"))
    end
  end

  def test_init_unsupported_framework_errors
    Dir.mktmpdir("better-auth-cli-init-parity") do |dir|
      status, _stdout, stderr = run_init_cli("--cwd", dir, "--framework", "nextjs")
      assert_equal 1, status
      assert_includes stderr, "Unsupported framework"
    end
  end

  def test_init_detect_framework_no_match_errors
    Dir.mktmpdir("better-auth-cli-init-parity") do |dir|
      status, _stdout, stderr = run_init_cli("--cwd", dir, "--detect-framework")
      assert_equal 1, status
      assert_includes stderr, "Could not detect"
    end
  end

  %w[rails hanami sinatra roda rack].each do |framework|
    define_method("test_init_framework_#{framework}_accepted") do
      Dir.mktmpdir("better-auth-cli-init-#{framework}") do |dir|
        status, _stdout, stderr = run_init_cli("--cwd", dir, "--framework", framework)
        if framework == "rack"
          assert_equal 0, status, stderr
        else
          assert_equal 1, status
          assert_includes stderr, "Gemfile"
        end
      end
    end
  end

  def test_init_force_overwrites_rack_config
    Dir.mktmpdir("better-auth-cli-init-parity") do |dir|
      config_path = File.join(dir, "config", "better_auth.rb")
      FileUtils.mkdir_p(File.dirname(config_path))
      File.write(config_path, "# old")

      run_init_cli("--cwd", dir, "--framework", "rack", "--force")

      refute_includes File.read(config_path), "# old"
      assert_includes File.read(config_path), "email_and_password"
    end
  end

  def test_init_plugin_and_env_together
    Dir.mktmpdir("better-auth-cli-init-parity") do |dir|
      status, stdout, stderr = run_init_cli(
        "--cwd", dir,
        "--framework", "rack",
        "--plugin", "jwt",
        "--write-env-example"
      )

      assert_equal 0, status, stderr
      assert_includes stdout, "create .env.example"
      assert_includes File.read(File.join(dir, "config", "better_auth.rb")), "plugin: jwt"
    end
  end
end
