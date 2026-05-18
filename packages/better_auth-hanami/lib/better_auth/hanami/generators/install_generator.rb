# frozen_string_literal: true

require "fileutils"
require_relative "migration_generator"
require_relative "relation_generator"

module BetterAuth
  module Hanami
    module Generators
      class InstallGenerator
        def initialize(destination_root: Dir.pwd)
          @destination_root = destination_root
        end

        def run
          create_provider
          create_task
          update_routes
          update_settings
          RelationGenerator.new(destination_root: destination_root).run
          MigrationGenerator.new(destination_root: destination_root).run
        end

        private

        attr_reader :destination_root

        def create_provider
          path = File.join(destination_root, "config/providers/better_auth.rb")
          return if File.exist?(path)

          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, provider_template)
        end

        def create_task
          path = File.join(destination_root, "lib/tasks/better_auth.rake")
          return if File.exist?(path)

          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, task_template)
        end

        def update_routes
          path = File.join(destination_root, "config/routes.rb")
          unless File.exist?(path)
            Kernel.warn("[better_auth-hanami] InstallGenerator: #{path} not found; skipping routes wiring. Add Hanami routes manually.")
            return
          end

          content = File.read(path)
          content = content.gsub(%(require "better_auth/hanami/routing"), %(require "better_auth/hanami"))
          content = dedupe_better_auth_requires(content)
          content = %(require "better_auth/hanami"\n) + content unless content.include?(%("better_auth/hanami"))
          content = content.sub("class Routes < Hanami::Routes\n", "class Routes < Hanami::Routes\n    include BetterAuth::Hanami::Routing\n") unless content.include?("include BetterAuth::Hanami::Routing")
          content = content.sub(/(include BetterAuth::Hanami::Routing\n)(?!\s*better_auth)/, "\\1    better_auth\n") unless content.match?(/^\s*better_auth\b/)
          File.write(path, content)
        end

        def update_settings
          path = File.join(destination_root, "config/settings.rb")
          unless File.exist?(path)
            Kernel.warn("[better_auth-hanami] InstallGenerator: #{path} not found; skipping settings wiring. Add better_auth_secret and better_auth_url manually.")
            return
          end

          content = File.read(path)
          required_url_setting = "setting :better_auth_url, constructor: Types::String.constrained(min_size: 1)"
          content = content.gsub("setting :better_auth_url, constructor: Types::String.optional", required_url_setting)
          if content.include?("setting :better_auth_secret")
            File.write(path, content)
            return
          end

          insertion = [
            "    setting :better_auth_secret, constructor: Types::String.constrained(min_size: 32)",
            "    #{required_url_setting}"
          ].join("\n")
          content = content.sub(/(class[ \t]+Settings[ \t]*<[ \t]*Hanami::Settings[ \t]*\n)/, "\\1#{insertion}\n")
          File.write(path, content)
        end

        def dedupe_better_auth_requires(content)
          previous = nil
          content.lines.each_with_object([]) do |line, output|
            stripped = line.strip
            next if stripped == previous && stripped == %(require "better_auth/hanami")

            output << line
            previous = stripped
          end.join
        end

        def provider_template
          <<~RUBY
            # frozen_string_literal: true

            Hanami.app.register_provider(:better_auth) do
              prepare do
                require "better_auth/hanami"
              end

              start do
                better_auth_url = target["settings"].better_auth_url.to_s
                raise "better_auth_url must be configured" if better_auth_url.empty?

                BetterAuth::Hanami.configure do |config|
                  config.secret = target["settings"].better_auth_secret
                  config.base_url = better_auth_url
                  config.base_path = "/api/auth"
                  config.database = ->(options) {
                    BetterAuth::Hanami::SequelAdapter.from_container(target, options)
                  }
                  config.trusted_origins = [better_auth_url]
                  config.email_and_password = {enabled: true}
                  config.plugins = []
                end

                auth = BetterAuth::Hanami.auth
                register "better_auth.auth", auth
                register "better_auth.rack_app", BetterAuth::Hanami::MountedApp.new(auth, mount_path: BetterAuth::Hanami.configuration.base_path)
              end
            end
          RUBY
        end

        def task_template
          <<~RUBY
            # frozen_string_literal: true

            require "better_auth/hanami"

            namespace :better_auth do
              desc "Create Better Auth Hanami provider, routes, settings, tasks, and base migration"
              task :init do
                BetterAuth::Hanami::Generators::InstallGenerator.new.run
              end

              namespace :generate do
                desc "Create the Better Auth Hanami base migration"
                task :migration do
                  BetterAuth::Hanami::Generators::MigrationGenerator.new.run
                end

                desc "Create Hanami relations and repos for Better Auth tables"
                task :relations do
                  BetterAuth::Hanami::Generators::RelationGenerator.new.run
                end
              end
            end
          RUBY
        end
      end
    end
  end
end
