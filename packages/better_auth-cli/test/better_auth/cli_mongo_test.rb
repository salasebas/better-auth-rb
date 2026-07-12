# frozen_string_literal: true

require_relative "../support/cli_test_case"

class BetterAuthCLISchemaMongoAdapter < BetterAuth::Adapters::Base
  def ensure_indexes!
    migration_table_names = BetterAuth::Schema.migration_tables(options).keys
    BetterAuth::Schema.auth_tables(options).flat_map do |_model, table|
      next [] unless migration_table_names.include?(table.fetch(:model_name))

      table.fetch(:fields).filter_map do |field, attributes|
        next if field == "id"
        next unless attributes[:unique] || attributes[:index]

        {
          collection: table.fetch(:model_name),
          field: attributes[:field_name] || BetterAuth::Schema.physical_name(field),
          unique: attributes[:unique] == true
        }
      end
    end
  end
end

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

  def test_mongo_indexes_uses_schema_derived_plugin_indexes
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_config(
        dir,
        <<~RUBY
          {
            secret: #{SECRET.inspect},
            database: ->(options) { BetterAuthCLISchemaMongoAdapter.new(options) },
            plugins: [
              BetterAuth::Plugin.new(
                id: "schema-index",
                schema: {
                  apiKey: {
                    model_name: "api_keys",
                    fields: {
                      lookupKey: {type: "string", required: true, index: true},
                      token: {type: "string", required: true, unique: true}
                    }
                  }
                }
              )
            ]
          }
        RUBY
      )

      status, stdout, stderr = run_cli("mongo", "indexes", "--cwd", dir, "--config", config_path)

      assert_equal 0, status, stderr
      assert_includes stdout, "ensured index api_keys.lookup_key"
      assert_includes stdout, "ensured unique index api_keys.token"
    end
  end

  def test_mongo_indexes_omits_schema_derived_indexes_with_migrations_disabled
    Dir.mktmpdir("better-auth-cli") do |dir|
      config_path = write_config(
        dir,
        <<~RUBY
          {
            secret: #{SECRET.inspect},
            database: ->(options) { BetterAuthCLISchemaMongoAdapter.new(options) },
            plugins: [
              BetterAuth::Plugin.new(
                id: "external-index",
                schema: {
                  auditLog: {
                    model_name: "audit_logs",
                    disable_migration: true,
                    fields: {lookupKey: {type: "string", required: true, index: true}}
                  }
                }
              )
            ]
          }
        RUBY
      )

      status, stdout, stderr = run_cli("mongo", "indexes", "--cwd", dir, "--config", config_path)

      assert_equal 0, status, stderr
      refute_includes stdout, "audit_logs.lookup_key"
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
