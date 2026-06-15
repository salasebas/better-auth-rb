# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "sqlite3"
require "stringio"
require "tmpdir"

class BetterAuthCLIFakeSQLConnection
  attr_reader :statements

  def initialize
    @statements = []
  end

  def execute(sql)
    statements << sql
    []
  end
end

class BetterAuthCLIFakeSQLAdapter < BetterAuth::Adapters::Base
  attr_reader :connection, :dialect

  def initialize(options, dialect:)
    super(options)
    @dialect = dialect.to_sym
    @connection = BetterAuthCLIFakeSQLConnection.new
  end
end

class BetterAuthCLIFakeMongoAdapter < BetterAuth::Adapters::Base
  def initialize(options, indexes:)
    super(options)
    @indexes = indexes
  end

  def ensure_indexes!
    @indexes
  end
end

module BetterAuthCLITestHelpers
  SECRET = "cli-secret-that-is-long-enough-for-validation"
  HARDENED_SECRET = "cli-hardened-secret-1234567890-ABCDEFGHIJKLMNOPQRSTUVWXYZ"

  def run_cli(*argv)
    stdout = StringIO.new
    stderr = StringIO.new
    status = BetterAuth::CLI.run(argv, stdout: stdout, stderr: stderr)
    [status, stdout.string, stderr.string]
  end

  def run_better_auth_executable(*argv)
    stdout, stderr, status = Open3.capture3(
      {"RUBYLIB" => better_auth_ruby_lib},
      RbConfig.ruby,
      better_auth_executable_path,
      *argv
    )
    [stdout, stderr, status]
  end

  def better_auth_executable_path
    File.expand_path("../../exe/better-auth", __dir__)
  end

  def better_auth_ruby_lib
    [
      File.expand_path("../../lib", __dir__),
      File.expand_path("../../../better_auth/lib", __dir__)
    ].join(File::PATH_SEPARATOR)
  end

  def write_config(dir, source, filename: "better_auth.rb")
    path = File.join(dir, filename)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
    path
  end

  def write_hash_config(dir, **options)
    filename = options.delete(:filename) || "better_auth.rb"
    write_config(dir, ruby_hash(options), filename: filename)
  end

  def write_sqlite_config(
    dir,
    secret: SECRET,
    base_url: nil,
    rate_limit: nil,
    plugins_source: nil,
    user_options_source: nil,
    session_options_source: nil,
    account_options_source: nil,
    verification_options_source: nil,
    advanced_source: nil
  )
    db_path = File.join(dir, "auth.sqlite3")
    write_config(
      dir,
      <<~RUBY
        {
          secret: #{secret.inspect},
          database: ->(options) { BetterAuth::Adapters::SQLite.new(options, path: #{db_path.inspect}) },
          email_and_password: {enabled: true}#{option_line(:base_url, base_url)}#{option_line(:rate_limit, rate_limit)}#{source_line(:user, user_options_source)}#{source_line(:session, session_options_source)}#{source_line(:account, account_options_source)}#{source_line(:verification, verification_options_source)}#{source_line(:advanced, advanced_source)}#{plugins_line(plugins_source)}
        }
      RUBY
    )
  end

  def write_fake_sql_config(
    dir,
    dialect:,
    secret: SECRET,
    rate_limit: nil,
    plugins_source: nil,
    user_options_source: nil,
    session_options_source: nil,
    account_options_source: nil,
    verification_options_source: nil,
    advanced_source: nil
  )
    write_config(
      dir,
      <<~RUBY
        {
          secret: #{secret.inspect},
          database: ->(options) { BetterAuthCLIFakeSQLAdapter.new(options, dialect: #{dialect.inspect}) },
          email_and_password: {enabled: true}#{option_line(:rate_limit, rate_limit)}#{source_line(:user, user_options_source)}#{source_line(:session, session_options_source)}#{source_line(:account, account_options_source)}#{source_line(:verification, verification_options_source)}#{source_line(:advanced, advanced_source)}#{plugins_line(plugins_source)}
        }
      RUBY
    )
  end

  def write_mongo_config(dir, indexes:)
    write_config(
      dir,
      <<~RUBY
        {
          secret: #{SECRET.inspect},
          database: ->(options) { BetterAuthCLIFakeMongoAdapter.new(options, indexes: #{ruby_hash(indexes)}) }
        }
      RUBY
    )
  end

  def sqlite_tables(dir)
    db = SQLite3::Database.new(File.join(dir, "auth.sqlite3"))
    db.execute("SELECT name FROM sqlite_master WHERE type = 'table'").flatten
  ensure
    db&.close
  end

  def sqlite_db_path(dir)
    File.join(dir, "auth.sqlite3")
  end

  def auth_for_sqlite_dir(dir, secret: SECRET, plugins: nil, **options)
    db_path = sqlite_db_path(dir)
    config = {
      secret: secret,
      database: ->(adapter_options) { BetterAuth::Adapters::SQLite.new(adapter_options, path: db_path) },
      email_and_password: {enabled: true}
    }.merge(options)
    config[:plugins] = plugins if plugins
    BetterAuth.auth(config)
  end

  def audit_plugin
    BetterAuth::Plugin.new(
      id: "audit-test",
      schema: {
        auditLog: {
          model_name: "audit_logs",
          fields: {
            action: {type: "string", required: true}
          }
        }
      }
    )
  end

  def audit_plugin_source
    <<~RUBY.strip
      [
        BetterAuth::Plugin.new(
          id: "audit-test",
          schema: {
            auditLog: {
              model_name: "audit_logs",
              fields: {
                action: {type: "string", required: true}
              }
            }
          }
        )
      ]
    RUBY
  end

  # CLI migration integration uses sqlite temp files by default.
  def db_integration_enabled?
    ENV["BETTER_AUTH_CLI_RUN_DB_INTEGRATION"] == "1"
  end

  def skip_db_integration_unless_enabled!
    skip "set BETTER_AUTH_CLI_RUN_DB_INTEGRATION=1 to run optional CLI database integration tests" unless db_integration_enabled?
  end

  private

  def option_line(name, value)
    value.nil? ? "" : ",\n  #{name}: #{ruby_hash(value)}"
  end

  def plugins_line(source)
    source ? ",\n  plugins: #{source}" : ""
  end

  def source_line(name, source)
    source ? ",\n  #{name}: #{source}" : ""
  end

  def ruby_hash(value)
    case value
    when Hash
      "{" + value.map { |key, item| "#{key.inspect} => #{ruby_hash(item)}" }.join(", ") + "}"
    when Array
      "[" + value.map { |item| ruby_hash(item) }.join(", ") + "]"
    when Symbol
      ":#{value}"
    else
      value.inspect
    end
  end
end
