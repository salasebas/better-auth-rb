# frozen_string_literal: true

require "minitest/autorun"
require "pathname"
require "yaml"

class TestPartitioningTest < Minitest::Test
  PARTITIONED_PACKAGES = %w[
    better_auth
    better_auth-cli
    better_auth-redis-storage
    better_auth-mongodb
    better_auth-mongo-adapter
    better_auth-api-key
    better_auth-passkey
    better_auth-oauth-provider
    better_auth-scim
    better_auth-sso
    better_auth-stripe
  ].freeze

  def test_every_partition_is_explicit_exhaustive_and_disjoint
    PARTITIONED_PACKAGES.each do |package|
      rakefile = File.read(File.join("packages", package, "Rakefile"))

      assert_includes rakefile, 'ALL_TEST_FILES = FileList["test/**/*_test.rb"].to_a.freeze', package
      assert_includes rakefile, "INTEGRATION_TEST_FILES", package
      assert_includes rakefile, "UNIT_TEST_FILES", package
      assert_includes rakefile, "UNIT_TEST_FILES & INTEGRATION_TEST_FILES", package
      assert_includes rakefile, "(UNIT_TEST_FILES + INTEGRATION_TEST_FILES).sort == ALL_TEST_FILES.sort", package
      assert_includes rakefile, "task.test_files = FileList[*UNIT_TEST_FILES]", package unless package == "better_auth" || package == "better_auth-cli"
      refute_match(/task\.pattern = "test\/\*\*\/\*_test\.rb"/, rakefile, package)
    end
  end

  def test_external_files_are_owned_only_by_integration_partitions
    expected = {
      "better_auth" => %w[adapters/postgres_test.rb adapters/mysql_test.rb adapters/mssql_test.rb],
      "better_auth-cli" => %w[cli_migrate_parity_test.rb],
      "better_auth-redis-storage" => %w[redis_storage_integration_test.rb],
      "better_auth-mongodb" => %w[adapters/mongodb_test.rb],
      "better_auth-mongo-adapter" => %w[adapters/mongodb_test.rb],
      "better_auth-api-key" => %w[adapter_matrix_test.rb redis_secondary_storage_integration_test.rb],
      "better_auth-passkey" => %w[adapter_matrix_test.rb],
      "better_auth-oauth-provider" => %w[adapter_smoke_test.rb],
      "better_auth-scim" => %w[scim_adapter_matrix_test.rb],
      "better_auth-sso" => %w[adapter_matrix_test.rb],
      "better_auth-stripe" => %w[stripe_adapter_matrix_test.rb]
    }

    expected.each do |package, files|
      rakefile = File.read(File.join("packages", package, "Rakefile"))
      files.each { |file| assert_includes rakefile, file, "#{package} must own #{file} as integration" }
    end
  end

  def test_endpoint_registry_contract_runs_only_from_workspace
    assert_path_exists "test/endpoint_registry_parity_test.rb"
    refute_path_exists "packages/better_auth/test/better_auth/endpoint_registry_parity_test.rb"

    contract = File.read("test/endpoint_registry_parity_test.rb")
    refute_match(/^\s*skip\b/, contract)
    assert_includes contract, "InventoryAuth.require_plugin_gems!"
  end

  def test_no_active_rubyauth_alias_package_or_configuration
    alias_package_path = File.join("packages", "ruby" + "auth")

    refute_path_exists alias_package_path
    refute_path_exists "test/rubyauth_alias_package_test.rb"

    active_paths = [
      "README.md",
      ".release.yml",
      ".release-please-manifest.json",
      "release-please-config.json",
      ".github/labeler.yml"
    ] + Dir[".github/workflows/*.{yml,yaml}"]
    active_paths.each do |path|
      refute_includes File.read(path), alias_package_path, path
    end
  end

  def test_integration_workflow_is_hybrid_and_strict
    workflow = File.read(".github/workflows/integration.yml")

    assert_includes workflow, "workflow_call:"
    assert_includes workflow, "type: boolean"
    assert_includes workflow, "merge_group:"
    assert_includes workflow, "dorny/paths-filter@7b450fff21473bca461d4b92ce414b9d0420d706"
    assert_includes workflow, "mongo:8.0"
    assert_includes workflow, "BETTER_AUTH_MONGODB_REPLICA_SET_URL"
    assert_includes workflow, "strict_minitest"
    assert_includes workflow, "strict_rspec"
    assert_includes workflow, '.result == "success" or .result == "skipped"'
    assert_includes workflow, %(bundle exec ruby -Itest -e 'require "./test/mysql_plugin_schema_smoke_test"')
    refute_match(/^\s+paths:/, workflow.lines.take_while { |line| line != "concurrency:\n" }.join)

    jobs = YAML.safe_load_file(".github/workflows/integration.yml", aliases: true).fetch("jobs")
    test_steps = jobs.values.flat_map { |job| Array(job["steps"]) }.select do |step|
      step.is_a?(Hash) &&
        step["run"].to_s.match?(/\brake test(?::[a-z_]+)?\b|\brspec\b|mysql_plugin_schema_smoke_test/)
    end
    refute_empty test_steps
    test_steps.each do |step|
      env = step.fetch("env", {})
      strict = env["RUBYOPT"].to_s.include?("strict_minitest") ||
        env["SPEC_OPTS"].to_s.include?("strict_rspec")
      assert strict, "#{step["name"] || step["run"]} must load a strict test helper"
    end
  end
end
