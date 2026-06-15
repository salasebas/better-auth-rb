# frozen_string_literal: true

require "json"

module BetterAuth
  class CLI
    module Info
      module_function

      def build(resolution)
        {
          "ruby" => ruby_info,
          "better_auth" => {"version" => BetterAuth::VERSION},
          "cli" => {"version" => CLI::VERSION},
          "config" => config_payload(resolution)
        }
      end

      def print(payload, stdout:)
        stdout.puts "Ruby #{payload.dig("ruby", "version")} (#{payload.dig("ruby", "engine")})"
        stdout.puts "Better Auth #{payload.dig("better_auth", "version")}"
        stdout.puts "CLI #{payload.dig("cli", "version")}"

        config = payload.fetch("config")
        if config["loaded"]
          stdout.puts "Config #{config["path"]}"
          doctor = config.fetch("doctor")
          stdout.puts "Doctor #{doctor["errors"].size} errors, #{doctor["warnings"].size} warnings, #{doctor["ok"].size} ok"
        else
          stdout.puts "Config not loaded"
          stdout.puts config["error"] if config["error"]
        end
      end

      def ruby_info
        {
          "version" => RUBY_VERSION,
          "engine" => RUBY_ENGINE
        }
      end

      def config_payload(resolution)
        return {"loaded" => false, "error" => resolution[:error]} unless resolution[:loaded]

        config = resolution.fetch(:config)
        auth = resolution.fetch(:auth)
        adapter = adapter_summary(auth)
        doctor = BetterAuth::Doctor.check(config)

        {
          "loaded" => true,
          "path" => resolution.fetch(:path),
          "base_url" => config.base_url.to_s,
          "base_path" => config.base_path.to_s,
          "adapter" => adapter[:name],
          "dialect" => adapter[:dialect],
          "tables" => BetterAuth::Schema.auth_tables(config).values.map { |table| table[:model_name] }.compact.sort,
          "endpoints_count" => auth.api.endpoints.size,
          "doctor" => BetterAuth::Doctor.as_json(doctor)
        }
      end

      def adapter_summary(auth)
        adapter = auth.context.adapter
        name = adapter.class.name.sub(/\ABetterAuth::Adapters::/, "")
        dialect = adapter.respond_to?(:dialect) ? adapter.dialect.to_s : nil
        {name: name, dialect: dialect}
      end
    end
  end
end
