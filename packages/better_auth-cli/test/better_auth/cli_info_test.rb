# frozen_string_literal: true

require "fileutils"
require_relative "../support/cli_test_case"

class CliInfoTest < BetterAuthCLITestCase
  def test_info_json_without_config_returns_loaded_false
    Dir.mktmpdir("better-auth-cli") do |dir|
      status, stdout, stderr = run_cli("info", "--json", "--cwd", dir)

      assert_equal 0, status, stderr
      payload = JSON.parse(stdout)
      assert_equal RUBY_VERSION, payload.dig("ruby", "version")
      assert_equal BetterAuth::VERSION, payload.dig("better_auth", "version")
      assert_equal BetterAuth::CLI::VERSION, payload.dig("cli", "version")
      assert_equal false, payload.dig("config", "loaded")
      refute payload.dig("config", "error")
    end
  end

  def test_info_json_with_config_returns_curated_summary_and_doctor
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(
        dir,
        secret: HARDENED_SECRET,
        base_url: "https://example.test"
      )

      status, stdout, stderr = run_cli("info", "--cwd", dir, "--json", "--config", config_path)

      assert_equal 0, status, stderr
      payload = JSON.parse(stdout)
      config = payload.fetch("config")
      assert_equal true, config["loaded"]
      assert_equal config_path, config["path"]
      assert_equal "https://example.test", config["base_url"]
      assert_includes config["tables"], "users"
      assert_operator config["endpoints_count"], :>, 0
      assert_kind_of Array, config.dig("doctor", "ok")
      assert_kind_of Array, config.dig("doctor", "warnings")
      assert_kind_of Array, config.dig("doctor", "errors")
    end
  end

  def test_info_json_includes_plugin_table_names_from_schema
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(dir, plugins_source: audit_plugin_source)

      status, stdout, stderr = run_cli("info", "--cwd", dir, "--json", "--config", config_path)

      assert_equal 0, status, stderr
      payload = JSON.parse(stdout)
      assert_includes payload.dig("config", "tables"), "audit_logs"
    end
  end

  def test_info_json_does_not_leak_sensitive_config_values
    sensitive_values = {
      secret: "my-production-secret-that-should-not-leak",
      password: "user-password-value",
      token: "bearer-token-value",
      api_key: "api-key-value",
      client_secret: "github-client-secret-value"
    }

    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_config(
        dir,
        <<~RUBY
          {
            secret: #{sensitive_values[:secret].inspect},
            database: :memory,
            email_and_password: {enabled: true},
            password: #{sensitive_values[:password].inspect},
            token: #{sensitive_values[:token].inspect},
            api_key: #{sensitive_values[:api_key].inspect},
            social_providers: {
              github: {
                client_id: "github-client-id",
                client_secret: #{sensitive_values[:client_secret].inspect}
              }
            }
          }
        RUBY
      )

      status, stdout, stderr = run_cli("info", "--cwd", dir, "--json", "--config", config_path)

      assert_equal 0, status, stderr
      sensitive_values.each_value do |value|
        refute_includes stdout, value
      end
      refute_includes stdout, "github-client-id"
    end
  end

  def test_info_text_output_includes_versions_and_doctor_summary
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_sqlite_config(
        dir,
        secret: BetterAuth::Configuration::DEFAULT_SECRET,
        base_url: "http://example.test"
      )

      status, stdout, stderr = run_cli("info", "--cwd", dir, "--config", config_path)

      assert_equal 0, status, stderr
      assert_includes stdout, "Ruby #{RUBY_VERSION}"
      assert_includes stdout, "Better Auth #{BetterAuth::VERSION}"
      assert_includes stdout, "CLI #{BetterAuth::CLI::VERSION}"
      assert_includes stdout, "Config #{config_path}"
      assert_includes stdout, "Doctor 1 errors"
    end
  end

  def test_info_with_missing_explicit_config_returns_error
    Dir.mktmpdir("better-auth-cli") do |dir|
      status, _stdout, stderr = run_cli("info", "--cwd", dir, "--config", File.join(dir, "missing.rb"))

      assert_equal 1, status
      assert_includes stderr, "Config file not found"
    end
  end

  def test_info_json_omits_framework_without_gemfile
    Dir.mktmpdir("better-auth-cli-info") do |dir|
      status, stdout, stderr = run_cli("info", "--json", "--cwd", dir)

      assert_equal 0, status, stderr
      payload = JSON.parse(stdout)
      refute payload.key?("framework")
    end
  end

  def test_info_json_detects_rails_framework_from_gemfile
    Dir.mktmpdir("better-auth-cli-info") do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"), "Rails.application")
      File.write(File.join(dir, "Gemfile"), 'gem "rails"')

      status, stdout, stderr = run_cli("info", "--json", "--cwd", dir)

      assert_equal 0, status, stderr
      payload = JSON.parse(stdout)
      assert_equal "rails", payload.dig("framework", "detected")
      assert_equal "gemfile", payload.dig("framework", "source")
    end
  end

  def test_info_json_includes_gems_from_gemfile
    Dir.mktmpdir("better-auth-cli-info") do |dir|
      File.write(File.join(dir, "Gemfile"), 'gem "better_auth-rails"')

      status, stdout, stderr = run_cli("info", "--json", "--cwd", dir)

      assert_equal 0, status, stderr
      payload = JSON.parse(stdout)
      assert payload.dig("gems", "better_auth_rails")
    end
  end

  def test_info_text_output_includes_framework_when_detected
    Dir.mktmpdir("better-auth-cli-info") do |dir|
      File.write(File.join(dir, "Gemfile"), 'gem "roda"')

      status, stdout, stderr = run_cli("info", "--cwd", dir)

      assert_equal 0, status, stderr
      assert_includes stdout, "Framework roda"
    end
  end
end
