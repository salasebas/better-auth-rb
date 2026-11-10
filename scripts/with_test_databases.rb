#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs a command against this worktree's own databases on the shared
# `docker compose -p better-auth` stack.
#
#   scripts/with_test_databases.rb bundle exec rake test:integration

require "digest"
require_relative "../test/support/test_databases"

abort "Usage: scripts/with_test_databases.rb COMMAND [ARGS...]" if ARGV.empty?

explicit = TestDatabases::CONNECTION_ENV.reject { |name| ENV.fetch(name, "").empty? }
abort "Unset #{explicit.join(", ")} to run against per-worktree test databases." unless explicit.empty?

if ENV.fetch(TestDatabases::WORKTREE_ID_ENV, "").empty?
  ENV[TestDatabases::WORKTREE_ID_ENV] = Digest::SHA256.hexdigest(File.realpath(File.expand_path("..", __dir__)))[0, 8]
end
database = TestDatabases.sql_database

def compose_exec(service, script, input)
  IO.popen(["docker", "compose", "-p", "better-auth", "exec", "-T", service, "sh", "-c", script], "w") { |io| io.write(input) }
  abort "Could not create test database on #{service}. Is the shared stack running?" unless $?.success?
end

compose_exec("postgres", 'psql -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" -d postgres', <<~SQL)
  SELECT 'CREATE DATABASE #{database}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '#{database}')\\gexec
SQL
compose_exec("mysql", 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot', <<~SQL)
  CREATE DATABASE IF NOT EXISTS `#{database}`;
  GRANT ALL PRIVILEGES ON `#{database}`.* TO 'user'@'%';
SQL

warn "Using test databases suffixed with _#{TestDatabases.worktree_id} (#{database})."
exec(*ARGV)
