# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../../better_auth/lib", __dir__)

require "better_auth/cli"
require "minitest/autorun"
require_relative "../support/cli_helpers"

class BetterAuthCLIInitTest < Minitest::Test
  include BetterAuthCLITestHelpers

  def test_init_without_flags_reports_cwd_and_framework_requirements
    status, _stdout, stderr = run_cli_strict("init")

    assert_equal 1, status
    assert_includes stderr, "--cwd"
    assert_includes stderr, "--framework"
  end

  def test_init_with_cwd_and_framework_rack_creates_config
    Dir.mktmpdir("better-auth-cli-init") do |dir|
      status, stdout, stderr = run_init_cli("--cwd", dir, "--framework", "rack")

      assert_equal 0, status, stderr
      assert_includes stdout, "create config/better_auth.rb"
      assert File.exist?(File.join(dir, "config", "better_auth.rb"))
      assert File.exist?(File.join(dir, "db", "better_auth", "migrate", ".keep"))
    end
  end

  def test_init_with_rack_skips_existing_config_without_force
    Dir.mktmpdir("better-auth-cli-init") do |dir|
      config_path = File.join(dir, "config", "better_auth.rb")
      FileUtils.mkdir_p(File.dirname(config_path))
      File.write(config_path, "# existing")

      status, stdout, stderr = run_init_cli("--cwd", dir, "--framework", "rack")

      assert_equal 0, status, stderr
      assert_includes stdout, "skip config/better_auth.rb already exists"
      assert_equal "# existing", File.read(config_path)
    end
  end

  def test_init_detect_framework_on_rails_like_tree
    Dir.mktmpdir("better-auth-cli-init") do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"), "Rails.application")
      write_gemfile(dir, 'gem "better_auth-rails"')

      runner = lambda do |_cwd, *args|
        assert_equal ["bundle", "exec", "rails", "generate", "better_auth:install"], args
        [0, "create config/initializers/better_auth.rb\n", ""]
      end

      status, stdout, stderr = run_init_cli("--cwd", dir, "--detect-framework", command_runner: runner)

      assert_equal 0, status, stderr
      assert_includes stdout, "create config/initializers/better_auth.rb"
    end
  end

  def test_init_detect_framework_reports_ambiguous_gemfile
    Dir.mktmpdir("better-auth-cli-init") do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"), "Rails.application")
      write_gemfile(dir, 'gem "sinatra"')

      status, _stdout, stderr = run_init_cli("--cwd", dir, "--detect-framework")

      assert_equal 1, status
      assert_includes stderr, "Ambiguous framework detection"
      assert_includes stderr, "rails"
      assert_includes stderr, "sinatra"
    end
  end

  def test_init_rails_without_gem_reports_pretty_error
    Dir.mktmpdir("better-auth-cli-init") do |dir|
      status, _stdout, stderr = run_init_cli("--cwd", dir, "--framework", "rails")

      assert_equal 1, status
      assert_includes stderr, "better_auth-rails"
      assert_includes stderr, "Gemfile"
    end
  end

  def test_init_rails_with_mocked_generator_prints_created_files
    Dir.mktmpdir("better-auth-cli-init") do |dir|
      write_gemfile(dir, 'gem "better_auth-rails"')

      runner = lambda do |_cwd, *args|
        assert_equal ["bundle", "exec", "rails", "generate", "better_auth:install"], args
        [0, "create config/initializers/better_auth.rb\n", ""]
      end

      status, stdout, stderr = run_init_cli("--cwd", dir, "--framework", "rails", command_runner: runner)

      assert_equal 0, status, stderr
      assert_includes stdout, "create config/initializers/better_auth.rb"
    end
  end

  def test_init_rejects_both_framework_and_detect_framework
    Dir.mktmpdir("better-auth-cli-init") do |dir|
      status, _stdout, stderr = run_init_cli("--cwd", dir, "--framework", "rack", "--detect-framework")

      assert_equal 1, status
      assert_includes stderr, "Pass only one of --framework or --detect-framework"
    end
  end

  def test_better_auth_executable_help_lists_init
    stdout, stderr, status = run_better_auth_executable("help")

    assert status.success?, stderr
    assert_includes stdout, "init"
    assert_includes stdout, "--framework"
  end

  private

  def write_gemfile(dir, *lines)
    File.write(File.join(dir, "Gemfile"), lines.join("\n") + "\n")
  end
end
