# frozen_string_literal: true

require "uri"

# Connection settings for the database-backed test suites.
#
# Explicit connection variables (BETTER_AUTH_POSTGRES_URL, ...) always win, as
# in CI. Otherwise the defaults target the shared Docker stack, and database
# names gain the BETTER_AUTH_TEST_WORKTREE_ID suffix when it is set, so suites
# in different worktrees never reset each other's tables.
module TestDatabases
  WORKTREE_ID_ENV = "BETTER_AUTH_TEST_WORKTREE_ID"
  SQL_DATABASE = "better_auth"
  CONNECTION_ENV = %w[
    BETTER_AUTH_POSTGRES_URL
    BETTER_AUTH_MYSQL_DATABASE
    BETTER_AUTH_MYSQL_URL
    BETTER_AUTH_MSSQL_URL
    BETTER_AUTH_MONGODB_URL
    BETTER_AUTH_MONGODB_DATABASE
  ].freeze

  module_function

  def worktree_id
    id = ENV.fetch(WORKTREE_ID_ENV, "")
    return if id.empty?
    return id if id.match?(/\A[a-z0-9]+\z/)

    raise ArgumentError, "#{WORKTREE_ID_ENV} must contain only lowercase letters and digits, got #{id.inspect}"
  end

  def namespaced(name)
    id = worktree_id
    id ? "#{name}_#{id}" : name
  end

  def sql_database
    namespaced(SQL_DATABASE)
  end

  def postgres_url
    ENV.fetch("BETTER_AUTH_POSTGRES_URL") { "postgres://user:password@localhost:5432/#{sql_database}" }
  end

  def mysql_options
    {
      host: ENV.fetch("BETTER_AUTH_MYSQL_HOST", "127.0.0.1"),
      port: ENV.fetch("BETTER_AUTH_MYSQL_PORT", "3306").to_i,
      username: ENV.fetch("BETTER_AUTH_MYSQL_USER", "user"),
      password: ENV.fetch("BETTER_AUTH_MYSQL_PASSWORD", "password"),
      database: ENV.fetch("BETTER_AUTH_MYSQL_DATABASE") { sql_database }
    }
  end

  def mysql_url
    ENV.fetch("BETTER_AUTH_MYSQL_URL") do
      options = mysql_options
      "mysql2://#{options[:username]}:#{options[:password]}@#{options[:host]}:#{options[:port]}/#{options[:database]}"
    end
  end

  def mssql_url
    ENV.fetch("BETTER_AUTH_MSSQL_URL") { "tinytds://sa:Password123!@127.0.0.1:1433/#{sql_database}?timeout=30" }
  end

  def mssql_master_url
    ENV.fetch("BETTER_AUTH_MSSQL_MASTER_URL", "tinytds://sa:Password123!@127.0.0.1:1433/master?timeout=30")
  end

  def mssql_database
    URI(mssql_url).path.delete_prefix("/")
  end

  def ensure_mssql_database
    require "sequel"
    name = mssql_database
    master = Sequel.connect(mssql_master_url)
    master.run("IF DB_ID(N'#{name.gsub("'", "''")}') IS NULL CREATE DATABASE [#{name.gsub("]", "]]")}]")
  ensure
    master&.disconnect
  end

  def mongodb_url(database)
    ENV.fetch("BETTER_AUTH_MONGODB_URL") { "mongodb://127.0.0.1:27017/#{namespaced(database)}" }
  end
end
