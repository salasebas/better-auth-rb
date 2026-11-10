# frozen_string_literal: true

ENV["BETTER_AUTH_URL"] ||= "http://localhost:3000"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "better_auth"

require "minitest/autorun"
require "minitest/mock"
require "minitest/spec"

require_relative "support/auth_test_helpers"
require_relative "support/password_test_helpers"
require_relative "../../../test/support/test_databases"

module BetterAuthMySQLTestHelpers
  def mysql_connection
    Mysql2::Client.new(
      **TestDatabases.mysql_options,
      symbolize_keys: false
    )
  end

  def reset_mysql_schema(connection)
    connection.query("SET FOREIGN_KEY_CHECKS = 0")
    mysql_table_names(connection).each do |table|
      connection.query("DROP TABLE IF EXISTS #{quote_mysql_identifier(table)}")
    end
  ensure
    connection&.query("SET FOREIGN_KEY_CHECKS = 1")
  end

  def mysql_table_names(connection)
    connection.query(<<~SQL).map { |row| row["table_name"] || row.fetch("TABLE_NAME") }
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = DATABASE()
    SQL
  end

  def quote_mysql_identifier(identifier)
    "`#{identifier.to_s.gsub("`", "``")}`"
  end
end

# Configure SimpleCov if running coverage
if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/test/"
  end
end
