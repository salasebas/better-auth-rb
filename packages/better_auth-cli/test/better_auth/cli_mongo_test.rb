# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliMongoTest < BetterAuthCLITestCase
  def test_unknown_mongo_subcommand_returns_error
    status, stdout, stderr = run_cli_strict("mongo", "wat")

    assert_equal 1, status
    assert_empty stdout
    assert_includes stderr, "Unknown mongo command: wat"
  end

  def test_missing_mongo_subcommand_returns_error
    status, stdout, stderr = run_cli_strict("mongo")

    assert_equal 1, status
    assert_empty stdout
    assert_includes stderr, "Unknown mongo command: (none)"
  end

  def test_mongo_indexes_calls_adapter_index_setup
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_mongo_config(
        dir,
        indexes: [
          {collection: "users", field: "email", unique: true},
          {collection: "sessions", field: "token", unique: false}
        ]
      )

      status, stdout, stderr = run_cli("mongo", "indexes", "--cwd", dir, "--config", config_path)

      assert_equal 0, status, stderr
      assert_includes stdout, "ensured unique index users.email"
      assert_includes stdout, "ensured index sessions.token"
    end
  end

  def test_mongo_indexes_reports_no_indexes_needed
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_mongo_config(dir, indexes: [])

      status, stdout, stderr = run_cli("mongo", "indexes", "--cwd", dir, "--config", config_path)

      assert_equal 0, status, stderr
      assert_includes stdout, "No MongoDB indexes needed."
    end
  end

  def test_mongo_indexes_reports_malformed_index_metadata
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_mongo_config(dir, indexes: [{collection: "users", unique: true}])

      status, _stdout, stderr = run_cli("mongo", "indexes", "--cwd", dir, "--config", config_path)

      assert_equal 1, status
      assert_includes stderr, "MongoDB index metadata must include collection and field"
    end
  end

  def test_mongo_indexes_reports_unsupported_adapter
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_hash_config(dir, secret: SECRET, database: :memory)

      status, _stdout, stderr = run_cli("mongo", "indexes", "--cwd", dir, "--config", config_path)

      assert_equal 1, status
      assert_includes stderr, "ensure_indexes"
    end
  end

  def test_mongo_indexes_discovers_config_under_cwd
    Dir.mktmpdir("better-auth-cli") do |dir|
      write_mongo_project_config(
        dir,
        indexes: [{collection: "users", field: "email", unique: true}]
      )

      status, stdout, stderr = run_cli("mongo", "indexes", "--cwd", dir, "--discover-config")

      assert_equal 0, status, stderr
      assert_includes stdout, "ensured unique index users.email"
    end
  end
end
