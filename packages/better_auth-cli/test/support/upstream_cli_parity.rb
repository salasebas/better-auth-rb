# frozen_string_literal: true

module BetterAuth
  module CLITestSupport
    module UpstreamCLIParity
      REPOSITORY_ROOT = File.expand_path("../../../..", __dir__)
      VERSION_FILE = File.join(REPOSITORY_ROOT, "reference/upstream-better-auth/VERSION.md")
      UPSTREAM_VERSION = File.read(VERSION_FILE)[/^\| Version \| `(\d+\.\d+\.\d+)` \|$/, 1]
      raise "Could not read pinned upstream version from #{VERSION_FILE}" unless UPSTREAM_VERSION

      UPSTREAM_ROOT = File.expand_path(
        "reference/upstream-src/#{UPSTREAM_VERSION}/repository/packages/cli",
        REPOSITORY_ROOT
      )

      EXCLUDED_UPSTREAM_TESTS = {
        "test/generate-all-db.test.ts" => "Prisma/Drizzle/Kysely codegen; Ruby CLI is SQL-only",
        "test/install-dependencies.test.ts" => "npm/yarn/pnpm/bun package installers; Ruby uses Bundler",
        "test/check-package-managers.test.ts" => "Node package manager detection; Ruby uses Bundler",
        "src/commands/init/utility/imports.test.ts" => "TypeScript import path wiring; no Ruby equivalent"
      }.freeze

      RUBY_CLI_TEST_OWNERS = {
        "test/generate.test.ts" => {
          owner: ["better_auth/cli_generate_test.rb", "better_auth/cli_generate_parity_test.rb"],
          status: :covered,
          plan: "018",
          notes: "SQL generate paths, dialects, plugins, strict flags"
        },
        "test/migrate.test.ts" => {
          owner: "better_auth/cli_migrate_test.rb",
          status: :covered,
          plan: "018",
          notes: "Migrate apply/status and --yes requirement"
        },
        "test/init.test.ts" => {
          owner: "better_auth/cli_init_test.rb",
          status: :covered,
          plan: "018",
          notes: "Non-interactive init with framework flags"
        },
        "test/get-config.test.ts" => {
          owner: "better_auth/cli_config_resolution_test.rb",
          status: :covered,
          plan: "018",
          notes: "Cwd, explicit config, and --discover-config resolution"
        },
        "test/info.test.ts" => {
          owner: "better_auth/cli_info_test.rb",
          status: :covered,
          plan: "018",
          notes: "JSON/text info with Gemfile framework and gem detection"
        },
        "src/commands/init/utility/framework.test.ts" => {
          owner: "better_auth/cli_framework_detect_test.rb",
          status: :covered,
          plan: "018",
          notes: "Ruby framework detection from Gemfile and markers"
        },
        "src/commands/init/utility/env.test.ts" => {
          owner: "better_auth/cli_init_env_test.rb",
          status: :covered,
          plan: "018",
          notes: "Init --write-env-example writes .env.example only"
        },
        "src/commands/init/utility/auth-config.test.ts" => {
          owner: "better_auth/cli_init_auth_config_test.rb",
          status: :covered,
          plan: "018",
          notes: "Rack scaffold auth config uses ENV placeholders"
        },
        "src/commands/init/utility/database.test.ts" => {
          owner: "better_auth/cli_init_database_test.rb",
          status: :covered,
          plan: "018",
          notes: "Init --database-dialect adds scaffold comments"
        },
        "src/commands/init/utility/plugin.test.ts" => {
          owner: "better_auth/cli_init_plugins_test.rb",
          status: :covered,
          plan: "018",
          notes: "Init --plugin flags append plugin placeholders to config"
        }
      }.freeze

      TEST_ROOT = File.expand_path("..", __dir__)

      module_function

      def upstream_test_paths
        Dir.glob(File.join(UPSTREAM_ROOT, "**", "*.test.ts")).map do |absolute|
          absolute.delete_prefix(UPSTREAM_ROOT + "/")
        end.sort
      end

      def owner_paths(entry)
        Array(entry[:owner])
      end

      def owner_exists?(relative_path)
        File.file?(File.join(TEST_ROOT, relative_path))
      end
    end
  end
end
