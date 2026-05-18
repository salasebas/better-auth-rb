# frozen_string_literal: true

module BetterAuth
  class Auth
    TELEMETRY_ADAPTER_IDS = {
      "BetterAuth::Adapters::Memory" => "memory",
      "BetterAuth::Adapters::Postgres" => "postgres",
      "BetterAuth::Adapters::MySQL" => "mysql",
      "BetterAuth::Adapters::SQLite" => "sqlite",
      "BetterAuth::Adapters::MSSQL" => "mssql"
    }.freeze

    TELEMETRY_DATABASE_IDS = {
      memory: "memory",
      postgres: "postgres",
      mysql: "mysql",
      sqlite: "sqlite",
      mssql: "mssql"
    }.freeze

    attr_reader :handler, :api, :options, :context, :error_codes, :telemetry

    def initialize(options = {})
      @options = Configuration.new(options)
      @context = Context.new(@options)
      @context.set_adapter(build_adapter)
      @context.set_internal_adapter(Adapters::InternalAdapter.new(@context.adapter, @options))
      @plugin_registry = PluginRegistry.new(@context)
      @plugin_registry.run_init!
      @error_codes = build_error_codes
      @endpoints = build_endpoints
      Router.check_endpoint_conflicts(@options, @options.logger)
      @api = API.new(@context, @endpoints)
      @handler = Router.new(@context, @endpoints)
      @telemetry = build_telemetry_publisher
    end

    def call(env)
      handler.call(env)
    end

    private

    def build_error_codes
      @plugin_registry.error_codes(BASE_ERROR_CODES)
    end

    def build_adapter
      return Adapters::Memory.new(options) if options.database.nil? || options.database == :memory
      return options.database.call(options) if options.database.respond_to?(:call)

      options.database
    end

    def build_endpoints
      Core.base_endpoints.merge(@plugin_registry.endpoints)
    end

    def build_telemetry_publisher
      require "better_auth/telemetry"
      BetterAuth::Telemetry.create(@options, telemetry_context)
    rescue LoadError
      noop_telemetry_publisher
    rescue => e
      log_telemetry_error(e)
      noop_telemetry_publisher
    end

    def telemetry_context
      {
        database: telemetry_database_id,
        adapter: telemetry_adapter_id,
        custom_track: nil,
        skip_test_check: false
      }
    end

    def telemetry_database_id
      configured = @options.database
      return "memory" if configured.nil?
      return TELEMETRY_DATABASE_IDS[configured] if configured.is_a?(Symbol) && TELEMETRY_DATABASE_IDS.key?(configured)
      return "adapter" if configured.respond_to?(:call)

      TELEMETRY_ADAPTER_IDS[configured.class.name] || "adapter"
    end

    def telemetry_adapter_id
      TELEMETRY_ADAPTER_IDS[@context.adapter.class.name] || @context.adapter.class.name
    end

    def noop_telemetry_publisher
      Class.new do
        def publish(_event) = nil

        def enabled? = false
      end.new
    end

    def log_telemetry_error(error)
      logger = @options.logger
      message = "[better-auth] telemetry creation failed: #{error.class}: #{error.message}"
      if logger.respond_to?(:error)
        logger.error(message)
      else
        Kernel.warn(message)
      end
    end
  end
end
