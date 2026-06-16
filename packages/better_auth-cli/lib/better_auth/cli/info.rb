# frozen_string_literal: true

require "json"
require_relative "framework_detect"

module BetterAuth
  class CLI
    module Info
      BETTER_AUTH_GEM_PATTERN = /
        \bgem\s+["'](better_auth(?:-[a-z0-9_]+)?)["']
      /ix

      module_function

      def build(resolution, cwd: nil)
        payload = {
          "ruby" => ruby_info,
          "better_auth" => {"version" => BetterAuth::VERSION},
          "cli" => {"version" => CLI::VERSION},
          "config" => config_payload(resolution)
        }
        payload.merge!(project_payload(cwd)) if cwd
        payload
      end

      def print(payload, stdout:)
        stdout.puts "Ruby #{payload.dig("ruby", "version")} (#{payload.dig("ruby", "engine")})"
        stdout.puts "Better Auth #{payload.dig("better_auth", "version")}"
        stdout.puts "CLI #{payload.dig("cli", "version")}"

        if (framework = payload["framework"])
          stdout.puts "Framework #{framework.dig("detected")} (#{framework.dig("source")})"
        end

        if (bundler = payload["bundler"])
          stdout.puts "Bundler #{bundler["version"]}" if bundler["version"]
        end

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

      def project_payload(cwd)
        gemfile = File.join(cwd, "Gemfile")
        return {} unless File.exist?(gemfile)

        payload = {}
        detection = FrameworkDetect.detect(cwd)
        if detection[:framework]
          payload["framework"] = {
            "detected" => detection[:framework],
            "source" => "gemfile"
          }
        end

        gems = parse_better_auth_gems(gemfile)
        payload["gems"] = gems unless gems.empty?
        payload["bundler"] = bundler_info if bundler_info
        payload
      end

      def parse_better_auth_gems(gemfile_path)
        content = File.read(gemfile_path)
        found = content.scan(BETTER_AUTH_GEM_PATTERN).flatten.uniq.sort
        return {} if found.empty?

        found.each_with_object({}) do |name, memo|
          key = (name == "better_auth") ? "better_auth" : name.tr("-", "_")
          memo[key] = gem_version(name)
        end
      end

      def gem_version(name)
        spec = Gem.loaded_specs[name.tr("-", "_")] || Gem.loaded_specs[name]
        return spec.version.to_s if spec

        "unknown"
      end

      def bundler_info
        return unless defined?(Bundler)

        version = Bundler::VERSION
        version ? {"version" => version} : nil
      rescue NameError
        nil
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
