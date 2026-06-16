# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliMongoParityTest < BetterAuthCLITestCase
  def test_mongo_indexes_strict_requires_cwd
    status, _stdout, stderr = run_cli_strict("mongo", "indexes")
    assert_equal 1, status
    assert_includes stderr, "--cwd"
  end

  def test_mongo_indexes_strict_requires_config_or_discover
    Dir.mktmpdir("better-auth-cli-mongo") do |dir|
      status, _stdout, stderr = run_cli_strict("mongo", "indexes", "--cwd", dir)
      assert_equal 1, status
      assert_includes stderr, "--config"
    end
  end

  %w[users sessions].each do |collection|
    define_method("test_mongo_indexes_with_#{collection}_metadata") do
      Dir.mktmpdir("better-auth-cli-mongo-#{collection}") do |dir|
        config_path = write_mongo_config(
          dir,
          indexes: [{collection: collection, field: "email", unique: true}]
        )

        status, stdout, stderr = run_cli("mongo", "indexes", "--cwd", dir, "--config", config_path)

        assert_equal 0, status, stderr
        assert_includes stdout, "#{collection}.email"
      end
    end
  end
end
