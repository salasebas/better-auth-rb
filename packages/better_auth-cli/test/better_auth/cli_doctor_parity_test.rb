# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliDoctorParityTest < BetterAuthCLITestCase
  def test_doctor_strict_requires_config_or_discover
    Dir.mktmpdir("better-auth-cli-doctor") do |dir|
      status, _stdout, stderr = run_cli_strict("doctor", "--cwd", dir)
      assert_equal 1, status
      assert_includes stderr, "--config"
    end
  end

  %w[--json].each do |flag|
    define_method("test_doctor_accepts_#{flag.delete_prefix("--")}_with_explicit_config") do
      Dir.mktmpdir("better-auth-cli-doctor") do |dir|
        config_path = write_sqlite_config(
          dir,
          secret: BetterAuth::Configuration::DEFAULT_SECRET,
          base_url: "http://example.test"
        )

        status, _stdout, stderr = run_cli("doctor", "--cwd", dir, "--config", config_path, flag)
        assert_equal 1, status, stderr
      end
    end
  end

  def test_doctor_discover_config_finds_project_config
    Dir.mktmpdir("better-auth-cli-doctor") do |dir|
      write_sqlite_project_config(
        dir,
        secret: BetterAuth::Configuration::DEFAULT_SECRET,
        base_url: "http://example.test"
      )

      status, _stdout, stderr = run_cli("doctor", "--cwd", dir, "--discover-config")
      assert_equal 1, status, stderr
    end
  end

  def test_doctor_points_mongodb_adapters_to_mongo_indexes
    Dir.mktmpdir("better-auth-cli-doctor-mongo") do |dir|
      config_path = write_mongo_config(dir, indexes: [])

      status, stdout, stderr = run_cli("doctor", "--cwd", dir, "--config", config_path)

      assert_equal 0, status, stderr
      assert_includes stdout, "better-auth mongo indexes"
      assert_includes stdout, "schema drift check skipped"
    end
  end

  %w[sqlite postgres mysql mssql].each do |dialect|
    define_method("test_generate_memory_config_succeeds_for_#{dialect}") do
      Dir.mktmpdir("better-auth-cli-doctor-#{dialect}") do |dir|
        config_path = write_hash_config(dir, secret: SECRET, database: :memory)
        output = File.join(dir, "out.sql")

        status, _stdout, stderr = run_cli(
          "generate",
          "--cwd", dir,
          "--config", config_path,
          "--dialect", dialect.to_s,
          "--output", output
        )
        assert_equal 0, status, stderr
      end
    end
  end
end
