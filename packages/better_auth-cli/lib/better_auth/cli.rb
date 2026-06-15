# frozen_string_literal: true

require "better_auth"
require "better_auth/cli/version"
require "better_auth/cli/info"
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
      dialect = BetterAuth::SQLMigration.normalize_dialect(options[:dialect] || adapter&.dialect || "postgres")
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
      options = parse_config_options(args)
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
      options = parse_config_options(args) do |parser, opts|
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
        payload = Info.build(resolution)
        render_info(payload, json: options[:json])
        return 0
      end

      resolution[:auth] = auth_for(resolution.fetch(:config))
      payload = Info.build(resolution)
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
      options = parse_config_options(args)
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
      options = parse_with_cwd(args) do |parser, opts|
        parser.on("--dialect DIALECT") { |value| opts[:dialect] = value }
        parser.on("--output PATH") { |value| opts[:output] = value }
      end
      require_option!(options, :output, "generate --output PATH is required")
      options[:config] = resolve_config!(options)
      options[:output] = resolve_path(options.fetch(:output), options[:cwd])
      options
    end

    def parse_migrate_options(args)
      options = parse_with_cwd(args) do |parser, opts|
        parser.on("--yes", "-y") { opts[:yes] = true }
      end
      options[:yes] ||= false
      options[:config] = resolve_config!(options)
      options
    end

    def parse_config_options(args)
      options = parse_with_cwd(args) do |parser, opts|
        yield parser, opts if block_given?
      end
      options[:config] = resolve_config!(options)
      options
    end

    def parse_info_options(args)
      options = parse_with_cwd(args) do |parser, opts|
        parser.on("--json") { opts[:json] = true }
      end
      options[:json] ||= false
      options
    end

    def resolve_config_for_info(options)
      if options[:config]
        path = resolve_path(options[:config], options[:cwd])
        raise Error, "Config file not found: #{path}" unless File.exist?(path)

        config = load_config(path)
        return {loaded: true, path: path, config: config}
      end

      CONFIG_PATHS.each do |relative|
        candidate = File.join(options[:cwd], relative)
        next unless File.exist?(candidate)

        config = load_config(candidate)
        return {loaded: true, path: candidate, config: config}
      end

      searched = CONFIG_PATHS.map { |relative| File.join(options[:cwd], relative) }.join(", ")
      {loaded: false, error: "No Better Auth config found. Searched: #{searched}. Pass --config PATH."}
    end

    def render_info(payload, json:)
      if json
        stdout.puts JSON.generate(payload)
      else
        Info.print(payload, stdout: stdout)
      end
    end

    def parse_with_cwd(args)
      options = {cwd: Dir.pwd}
      OptionParser.new do |parser|
        parser.on("--cwd PATH") { |value| options[:cwd] = File.expand_path(value) }
        parser.on("--config PATH") { |value| options[:config] = value }
        yield parser, options if block_given?
      end.parse!(args)
      validate_cwd!(options[:cwd])
      options
    end

    def validate_cwd!(cwd)
      raise Error, "--cwd is not a directory: #{cwd}" unless File.directory?(cwd)
    end

    def resolve_config!(options)
      if options[:config]
        return resolve_path(options[:config], options[:cwd])
      end

      CONFIG_PATHS.each do |relative|
        candidate = File.join(options[:cwd], relative)
        return candidate if File.exist?(candidate)
      end

      searched = CONFIG_PATHS.map { |relative| File.join(options[:cwd], relative) }.join(", ")
      raise Error, "No Better Auth config found. Searched: #{searched}. Pass --config PATH."
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
          better-auth generate [--cwd PATH] [--config PATH] --dialect DIALECT --output PATH
          better-auth migrate [--cwd PATH] [--config PATH] --yes
          better-auth migrate status [--cwd PATH] [--config PATH]
          better-auth doctor [--cwd PATH] [--config PATH] [--json]
          better-auth info [--cwd PATH] [--config PATH] [--json]
          better-auth secret [--raw]
          better-auth mongo indexes [--cwd PATH] [--config PATH]

        When --config is omitted, the CLI searches under --cwd (default: current directory):
          #{CONFIG_PATHS.join(", ")}
      TEXT
    end
  end
end
