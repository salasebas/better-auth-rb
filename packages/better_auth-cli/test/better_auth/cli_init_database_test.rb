# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliInitDatabaseTest < BetterAuthCLITestCase
  def test_database_dialect_adds_comment_to_scaffold
    Dir.mktmpdir("better-auth-cli-init-db") do |dir|
      run_init_cli("--cwd", dir, "--framework", "rack", "--database-dialect", "postgres")
      content = File.read(File.join(dir, "config", "better_auth.rb"))

      assert_includes content, "Target dialect hint: postgres"
    end
  end

  %w[sqlite mysql mssql].each do |dialect|
    define_method("test_database_dialect_#{dialect}_comment") do
      Dir.mktmpdir("better-auth-cli-init-db-#{dialect}") do |dir|
        run_init_cli("--cwd", dir, "--framework", "rack", "--database-dialect", dialect)
        content = File.read(File.join(dir, "config", "better_auth.rb"))
        assert_includes content, "Target dialect hint: #{dialect}"
      end
    end
  end

  def test_database_dialect_omitted_has_no_hint_comment
    Dir.mktmpdir("better-auth-cli-init-db") do |dir|
      run_init_cli("--cwd", dir, "--framework", "rack")
      content = File.read(File.join(dir, "config", "better_auth.rb"))

      refute_includes content, "Target dialect hint:"
    end
  end
end
