# frozen_string_literal: true

require "better_auth"
require "better_auth/cli/version"
require "better_auth/cli/info"
require "better_auth/cli/errors"
require "better_auth/cli/init"
require "better_auth/cli/upgrade"
require "better_auth/doctor"
require "better_auth/sql_migration"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "securerandom"

module BetterAuth
  class CLI
    class Error < StandardError; end

    CONFIG_PATHS = [
      "config/better_auth.rb",
      "config/auth.rb",
      "better_auth.rb",
      "auth.rb"
    ].freeze

    CONFIG_BACKED_COMMANDS = %w[generate migrate doctor info mongo].freeze

    class << self
      attr_accessor :configuration

      def configure(value = nil)
        @configuration = block_given? ? yield : value
      end

      def run(argv = ARGV, stdout: $stdout, stderr: $stderr)
        new(argv, stdout: stdout, stderr: stderr).run
      rescue Error, BetterAuth::SQLMigration::UnsupportedAdapterError, BetterAuth::Error, OptionParser::ParseError => error
        stderr.puts error.message
        1
      end
    end

    def initialize(argv, stdout:, stderr:)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
    end

    def run
      command = argv.shift
      case command
      when "generate"
        generate(argv)
      when "migrate"
        migrate(argv)
      when "doctor"
        doctor(argv)
      when "secret"
        secret(argv)
      when "info"
        info(argv)
      when "init"
        Init.run(argv, stdout: stdout, stderr: stderr)
      when "upgrade"
        Upgrade.run(argv, stdout: stdout, stderr: stderr)
      when "mongo"
        mongo(argv)
      when "-h", "--help", "help", nil
        stdout.puts usage
        0
      else
        raise Error, "Unknown command: #{command}"
      end
    end

    private

    attr_reader :argv, :stdout, :stderr

    def generate(args)
      options = parse_generate_options(args)
      config = load_config(options.fetch(:config))
      adapter = sql_adapter_for(config)
      connection = adapter&.connection
      dialect = BetterAuth::SQLMigration.normalize_dialect(options.fetch(:dialect))
      sql = if connection
        BetterAuth::SQLMigration.render_pending(config, connection: connection, dialect: dialect, generator: "better_auth-cli")
      else
        BetterAuth::SQLMigration.render(config, dialect: dialect, generator: "better_auth-cli")
      end

      if sql.empty?
        stdout.puts "No migrations needed."
        return 0
      end

      output = options.fetch(:output)
      FileUtils.mkdir_p(File.dirname(output))
      File.write(output, sql)
      stdout.puts "generated #{output}"
      0
    end

    def migrate(args)
      if args.first == "status"
        args.shift
        return migration_status(args)
      end

      options = parse_migrate_options(args)
      raise Error, "Pass --yes to apply migrations." unless options[:yes]

      auth = auth_for(load_config(options.fetch(:config)))
      migrated = BetterAuth::SQLMigration.migrate_pending(auth)
      stdout.puts(migrated ? "migration completed successfully." : "No migrations needed.")
      0
    end

    def migration_status(args)
      options = parse_config_options("migrate status", args)
      config = load_config(options.fetch(:config))
      adapter = required_sql_adapter_for(config)
      plan = BetterAuth::SQLMigration.plan(config, connection: adapter.connection, dialect: adapter.dialect)

      if plan.empty?
        stdout.puts "No migrations needed."
      else
        plan.to_create.each { |change| stdout.puts "create table #{change.table_name}" }
        plan.to_add.each { |change| stdout.puts "add #{change.fields.keys.join(", ")} to #{change.table_name}" }
        plan.to_index.each { |change| stdout.puts "create index #{change.name}" }
        plan.warnings.each { |warning| stdout.puts "warning: #{warning}" }
      end
      0
    end

    def doctor(args)
      options = parse_config_options("doctor", args) do |parser, opts|
        parser.on("--json") { opts[:json] = true }
      end
      options[:json] ||= false
      config = load_config(options.fetch(:config))
      result = BetterAuth::Doctor.check(config)
      if options[:json]
        stdout.puts JSON.generate(BetterAuth::Doctor.as_json(result))
        return result.success? ? 0 : 1
      end

      BetterAuth::Doctor.print(result, stdout: stdout, stderr: stderr)
    end

    def secret(args)
      options = {raw: false}
      OptionParser.new do |parser|
        parser.on("--raw") { options[:raw] = true }
      end.parse!(args)

      value = SecureRandom.hex(32)
      stdout.puts(options[:raw] ? value : "BETTER_AUTH_SECRET=#{value}")
      0
    end

    def info(args)
      options = parse_info_options(args)
      resolution = resolve_config_for_info(options)
      unless resolution[:loaded]
        payload = Info.build(resolution, cwd: options[:cwd])
        render_info(payload, json: options[:json])
        return 0
      end

      resolution[:auth] = auth_for(resolution.fetch(:config))
      payload = Info.build(resolution, cwd: options[:cwd])
      render_info(payload, json: options[:json])
      0
    end

    def mongo(args)
      command = args.shift
      case command
      when "indexes"
        mongo_indexes(args)
      else
        raise Error, "Unknown mongo command: #{command || "(none)"}"
      end
    end

    def mongo_indexes(args)
      options = parse_config_options("mongo indexes", args)
      auth = auth_for(load_config(options.fetch(:config)))
      adapter = auth.context.adapter
      unless adapter.respond_to?(:ensure_indexes!)
        raise Error, "MongoDB index setup requires an adapter that supports ensure_indexes!"
      end

      indexes = adapter.ensure_indexes!
      if indexes.empty?
        stdout.puts "No MongoDB indexes needed."
      else
        indexes.each do |index|
          validate_mongo_index!(index)
          unique = index[:unique] ? " unique" : ""
          stdout.puts "ensured#{unique} index #{index[:collection]}.#{index[:field]}"
        end
      end
      0
    end

    def parse_generate_options(args)
      options = parse_with_cwd("generate", args, require_config: true) do |parser, opts|
        parser.on("--dialect DIALECT") { |value| opts[:dialect] = value }
        parser.on("--output PATH") { |value| opts[:output] = value }
      end
      unless options[:dialect]
        raise Error, Errors.missing_option("generate", "--dialect", [
          "Example: better-auth generate --cwd . --config config/better_auth.rb --dialect sqlite --output db/auth.sql"
        ])
      end
      require_option!(options, :output, "generate --output PATH is required")
      options[:output] = resolve_path(options.fetch(:output), options[:cwd])
      options
    end

    def parse_migrate_options(args)
      options = parse_with_cwd("migrate", args, require_config: true) do |parser, opts|
        parser.on("--yes", "-y") { opts[:yes] = true }
      end
      options[:yes] ||= false
      options
    end

    def parse_config_options(command, args)
      parse_with_cwd(command, args, require_config: true) do |parser, opts|
        yield parser, opts if block_given?
      end
    end

    def parse_info_options(args)
      parse_with_cwd("info", args, require_config: false) do |parser, opts|
        parser.on("--json") { opts[:json] = true }
      end.tap { |options| options[:json] ||= false }
    end

    def resolve_config_for_info(options)
      if options[:config]
        path = resolve_path(options[:config], options[:cwd])
        raise Error, "Config file not found: #{path}" unless File.exist?(path)

        config = load_config(path)
        return {loaded: true, path: path, config: config}
      end

      if options[:discover_config]
        discovered = discover_config_path(options[:cwd])
        return {loaded: false, error: discovered.fetch(:error)} if discovered[:error]

        path = discovered.fetch(:path)
        config = load_config(path)
        return {loaded: true, path: path, config: config}
      end

      {loaded: false}
    end

    def render_info(payload, json:)
      if json
        stdout.puts JSON.generate(payload)
      else
        Info.print(payload, stdout: stdout)
      end
    end

    def parse_with_cwd(command, args, require_config:)
      options = {}
      OptionParser.new do |parser|
        parser.on("--cwd PATH") { |value| options[:cwd] = File.expand_path(value) }
        parser.on("--config PATH") { |value| options[:config] = value }
        parser.on("--discover-config") { options[:discover_config] = true }
        yield parser, options if block_given?
      end.parse!(args)

      require_cwd!(command, options)
      validate_cwd!(options[:cwd])
      assign_config_path!(command, options) if require_config
      options
    end

    def require_cwd!(command, options)
      return if options[:cwd]

      raise Error, Errors.missing_option(command, "--cwd", example_lines(command))
    end

    def example_lines(command)
      case command
      when "generate"
        ["Example: better-auth generate --cwd . --config config/better_auth.rb --dialect sqlite --output db/auth.sql"]
      when "migrate", "migrate status"
        ["Example: better-auth #{command} --cwd . --config config/better_auth.rb"]
      when "doctor", "mongo indexes", "info"
        ["Example: better-auth #{command} --cwd . --config config/better_auth.rb"]
      else
        ["Example: better-auth #{command} --cwd . --config config/better_auth.rb"]
      end
    end

    def assign_config_path!(command, options)
      if options[:config]
        options[:config] = resolve_path(options[:config], options[:cwd])
        return
      end

      unless options[:discover_config]
        raise Error, Errors.missing_option(command, "--config", [
          "Pass --config PATH or add --discover-config to search under --cwd.",
          "Example: better-auth #{command} --cwd . --discover-config"
        ])
      end

      discovered = discover_config_path(options[:cwd])
      if discovered[:path]
        options[:config] = discovered.fetch(:path)
        return
      end

      raise Error, discovered.fetch(:error)
    end

    def discover_config_path(cwd)
      CONFIG_PATHS.each do |relative|
        candidate = File.join(cwd, relative)
        return {path: candidate} if File.exist?(candidate)
      end

      searched = CONFIG_PATHS.map { |relative| File.join(cwd, relative) }.join(", ")
      {
        error: "No Better Auth config found. Searched: #{searched}. Pass --config PATH."
      }
    end

    def validate_cwd!(cwd)
      raise Error, "--cwd is not a directory: #{cwd}" unless File.directory?(cwd)
    end

    def resolve_path(path, cwd)
      return path if Pathname.new(path).absolute?

      File.expand_path(path, cwd)
    end

    def require_option!(options, key, message)
      raise Error, message unless options[key]
    end

    def load_config(path)
      raise Error, "Config file not found: #{path}" unless File.exist?(path)

      self.class.configure(nil)
      result = begin
        TOPLEVEL_BINDING.eval(File.read(path), path)
      rescue => error
        raise Error, error.message
      end
      value = normalize_config_value(result) || self.class.configuration
      raise Error, "Config file must return a Hash, BetterAuth::Configuration, or BetterAuth::Auth" unless value

      BetterAuth::SQLMigration.configuration_for(value)
    end

    def normalize_config_value(value)
      value if value.is_a?(Hash) || value.is_a?(BetterAuth::Configuration) || value.is_a?(BetterAuth::Auth)
    end

    def validate_mongo_index!(index)
      return if index[:collection] && index[:field]

      raise Error, "MongoDB index metadata must include collection and field"
    end

    def sql_adapter_for(config)
      required_sql_adapter_for(config)
    rescue BetterAuth::SQLMigration::UnsupportedAdapterError
      nil
    end

    def required_sql_adapter_for(config)
      adapter = auth_for(config).context.adapter
      unless adapter.respond_to?(:dialect) && adapter.respond_to?(:connection)
        raise BetterAuth::SQLMigration::UnsupportedAdapterError,
          "Better Auth SQL migrations require core SQL adapters with connection and dialect support"
      end

      adapter
    end

    def auth_for(config)
      return config if config.is_a?(BetterAuth::Auth)

      BetterAuth.auth(config.to_h)
    end

    def usage
      <<~TEXT
        Usage:
          better-auth init --cwd PATH (--framework NAME | --detect-framework) [--force]
          better-auth upgrade --cwd PATH [--yes]
          better-auth generate --cwd PATH (--config PATH | --discover-config) --dialect DIALECT --output PATH
          better-auth migrate --cwd PATH (--config PATH | --discover-config) --yes
          better-auth migrate status --cwd PATH (--config PATH | --discover-config)
          better-auth doctor --cwd PATH (--config PATH | --discover-config) [--json]
          better-auth info --cwd PATH [--config PATH] [--discover-config] [--json]
          better-auth secret [--raw]
          better-auth mongo indexes --cwd PATH (--config PATH | --discover-config)

        --discover-config searches under --cwd for: #{CONFIG_PATHS.join(", ")}
        init frameworks: rails, hanami, sinatra, roda, rack (rack requires --framework, never auto-detected)
      TEXT
    end
  end
end
