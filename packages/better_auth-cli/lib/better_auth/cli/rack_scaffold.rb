# frozen_string_literal: true

require "fileutils"

module BetterAuth
  class CLI
    module RackScaffold
      CONFIG_PATH = "config/better_auth.rb"
      MIGRATIONS_DIR = "db/better_auth/migrate"
      ENV_EXAMPLE_PATH = ".env.example"

      SUPPORTED_PLUGINS = %w[
        two_factor
        username
        organization
        email_otp
        magic_link
        bearer
        jwt
        anonymous
      ].freeze

      module_function

      def write(cwd:, force: false, database_dialect: nil, plugins: [], write_env_example: false, stdout: $stdout)
        config_path = File.join(cwd, CONFIG_PATH)
        migrations_path = File.join(cwd, MIGRATIONS_DIR)
        created = []

        if File.exist?(config_path) && !force
          stdout.puts "skip #{CONFIG_PATH} already exists"
        else
          FileUtils.mkdir_p(File.dirname(config_path))
          File.write(config_path, config_template(database_dialect: database_dialect, plugins: plugins))
          created << CONFIG_PATH
          stdout.puts "create #{CONFIG_PATH}"
        end

        FileUtils.mkdir_p(migrations_path)
        keep_path = File.join(migrations_path, ".keep")
        unless File.exist?(keep_path)
          File.write(keep_path, "")
          created << "#{MIGRATIONS_DIR}/.keep"
          stdout.puts "create #{MIGRATIONS_DIR}/.keep"
        end

        if write_env_example
          env_path = File.join(cwd, ENV_EXAMPLE_PATH)
          if force || !File.exist?(env_path)
            File.write(env_path, env_example_template)
            created << ENV_EXAMPLE_PATH
            stdout.puts "create #{ENV_EXAMPLE_PATH}"
          end
        end

        unless created.empty?
          stdout.puts <<~MSG

            Next steps:
              1. Set BETTER_AUTH_SECRET and BETTER_AUTH_URL in your environment
              2. Replace `database: :memory` with your SQL adapter in #{CONFIG_PATH}
              3. Mount BetterAuth.auth in your Rack app
              4. Run: better-auth doctor --cwd . --config #{CONFIG_PATH}
              5. Run: better-auth migrate --cwd . --config #{CONFIG_PATH} --yes
          MSG
        end

        {created: created, skipped: created.empty? ? [CONFIG_PATH] : []}
      end

      def config_template(database_dialect: nil, plugins: [])
        dialect_comment = database_dialect ? "# Target dialect hint: #{database_dialect}\n" : ""
        plugin_lines = plugin_snippet(plugins)

        <<~RUBY
          # frozen_string_literal: true

          require "better_auth"

          #{dialect_comment}# Set BETTER_AUTH_SECRET (32+ chars) via ENV — never commit secrets.
          # Replace :memory with your SQL adapter before running migrations.
          BetterAuth.auth(
            secret: ENV.fetch("BETTER_AUTH_SECRET"),
            base_url: ENV.fetch("BETTER_AUTH_URL"),
            database: :memory,
            email_and_password: {enabled: true},
            plugins: #{plugin_lines}
          )
        RUBY
      end

      def plugin_snippet(plugins)
        ids = Array(plugins).map(&:to_s).uniq
        unknown = ids - SUPPORTED_PLUGINS
        raise CLI::Error, "Unsupported init plugin(s): #{unknown.join(", ")}. Supported: #{SUPPORTED_PLUGINS.join(", ")}" if unknown.any?

        return "[]" if ids.empty?

        entries = ids.map { |id| "# plugin: #{id} — add BetterAuth::Plugin configuration here" }
        "[\n  #{entries.join(",\n  ")}\n]"
      end

      def env_example_template
        <<~ENV
          # Copy to .env and fill in values. Do not commit .env.
          BETTER_AUTH_SECRET=
          BETTER_AUTH_URL=
        ENV
      end
    end
  end
end
