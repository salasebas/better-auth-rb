# frozen_string_literal: true

require "fileutils"
require "rake"
require "better_auth/grape"

namespace :better_auth do
  desc "Create the Better Auth Grape config and migration directory"
  task :install do
    config_path = "config/better_auth.rb"
    FileUtils.mkdir_p(File.dirname(config_path))
    if File.exist?(config_path)
      puts "skip #{config_path} already exists"
    else
      File.write(config_path, BetterAuth::Grape.default_config_template)
      puts "create #{config_path}"
    end

    FileUtils.mkdir_p(BetterAuth::Grape::Migration::DEFAULT_MIGRATIONS_PATH)
  end

  namespace :generate do
    desc "Create the Better Auth SQL migration"
    task :migration do
      BetterAuth::Grape.load_app_config!
      dialect = BetterAuth::Grape::Migration.normalize_dialect(BetterAuth::Env.get("BETTER_AUTH_DIALECT") || BetterAuth::Env.get("BETTER_AUTH_DATABASE_DIALECT") || "postgres")
      config = BetterAuth::Grape.migration_configuration
      path = BetterAuth::Grape::Migration.generate(config, dialect: dialect)
      puts "create #{path}"
    end
  end

  desc "Run pending Better Auth SQL migrations"
  task :migrate do
    BetterAuth::Grape.load_app_config!
    BetterAuth::Grape::Migration.migrate(BetterAuth::Grape.auth)
  end

  desc "Print Better Auth Grape mount information"
  task :routes do
    BetterAuth::Grape.load_app_config!
    mount_path = BetterAuth::Grape.configuration.base_path
    puts "#{mount_path}/* -> BetterAuth.auth"
    puts "Core routes are handled by Better Auth; use the OpenAPI plugin or HTTP API docs for endpoint details."
  end
end
