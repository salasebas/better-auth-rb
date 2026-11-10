#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs a command against this worktree's own databases on the shared
# `docker compose -p better-auth` stack, or drops the databases left behind
# by deleted worktrees.
#
#   scripts/with_test_databases.rb bundle exec rake test:integration
#   scripts/with_test_databases.rb --prune [--dry-run]

require "digest"
require_relative "../test/support/test_databases"

ROOT = File.expand_path("..", __dir__)
USAGE = "Usage: scripts/with_test_databases.rb COMMAND [ARGS...] | --prune [--dry-run]"
GENERATED_SUFFIX = /_(?<id>[0-9a-f]{8})\z/

POSTGRES = 'psql -v ON_ERROR_STOP=1 -qAt -U "$POSTGRES_USER" -d postgres'
MYSQL = 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N'
# The SQL Server image moved sqlcmd to mssql-tools18, which also needs -C to trust the self-signed certificate.
SQLCMD = 'if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then set -- /opt/mssql-tools18/bin/sqlcmd -C; else set -- /opt/mssql-tools/bin/sqlcmd; fi; "$@" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -b -h -1 -W -i /dev/stdin'
# mongosh reading a script from stdin echoes prompts and exits 0 on errors; --eval does neither.
MONGOSH = 'mongosh --quiet --eval "$(cat)"'

PRUNABLE = {
  "postgres" => [POSTGRES, "SELECT datname FROM pg_database", ->(name) { %(DROP DATABASE "#{name}" WITH (FORCE)) }],
  "mysql" => [MYSQL, "SHOW DATABASES", ->(name) { "DROP DATABASE `#{name}`" }],
  "mssql" => [SQLCMD, "SET NOCOUNT ON; SELECT name FROM sys.databases",
    ->(name) { "ALTER DATABASE [#{name}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [#{name}]" }],
  "mongodb" => [MONGOSH, "db.adminCommand({listDatabases: 1, nameOnly: true}).databases.forEach((d) => print(d.name))",
    ->(name) { %(db.getSiblingDB("#{name}").dropDatabase()) }]
}.freeze

def generated_worktree_id(path)
  Digest::SHA256.hexdigest(File.realpath(path))[0, 8]
end

def compose_exec(service, script, input)
  output = IO.popen(["docker", "compose", "-p", "better-auth", "exec", "-T", service, "sh", "-c", script], "r+") do |io|
    io.write(input)
    io.close_write
    io.read
  end
  abort "Command failed on #{service}. Is the shared stack running?" unless $?.success?
  output
end

def live_worktree_ids
  listing = IO.popen(["git", "-C", ROOT, "worktree", "list", "--porcelain"], &:read)
  abort "git worktree list failed." unless $?.success?
  paths = listing.scan(/^worktree (.+)$/).flatten.select { |path| File.exist?(path) }
  ids = paths.map { |path| generated_worktree_id(path) }
  abort "git worktree list did not include this worktree (#{ROOT})." unless ids.include?(generated_worktree_id(ROOT))
  ids
end

def stale?(name, live_ids)
  id = name[GENERATED_SUFFIX, :id]
  !id.nil? && !live_ids.include?(id)
end

def prune(dry_run:)
  live_ids = live_worktree_ids
  PRUNABLE.each do |service, (client, list, drop)|
    compose_exec(service, client, list).split("\n").map(&:strip).select { |name| stale?(name, live_ids) }.each do |name|
      if dry_run
        puts "Would drop #{service} database #{name}"
      else
        compose_exec(service, client, drop.call(name))
        puts "Dropped #{service} database #{name}"
      end
    end
  end
end

abort USAGE if ARGV.empty?

if ARGV.first == "--prune"
  abort USAGE unless ARGV == ["--prune"] || ARGV == ["--prune", "--dry-run"]
  prune(dry_run: ARGV.include?("--dry-run"))
  exit
end

explicit = TestDatabases::CONNECTION_ENV.reject { |name| ENV.fetch(name, "").empty? }
abort "Unset #{explicit.join(", ")} to run against per-worktree test databases." unless explicit.empty?

ENV[TestDatabases::WORKTREE_ID_ENV] = generated_worktree_id(ROOT) if ENV.fetch(TestDatabases::WORKTREE_ID_ENV, "").empty?
database = TestDatabases.sql_database

compose_exec("postgres", POSTGRES, <<~SQL)
  SELECT 'CREATE DATABASE #{database}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '#{database}')\\gexec
SQL
compose_exec("mysql", MYSQL, <<~SQL)
  CREATE DATABASE IF NOT EXISTS `#{database}`;
  GRANT ALL PRIVILEGES ON `#{database}`.* TO 'user'@'%';
SQL

warn "Using test databases suffixed with _#{TestDatabases.worktree_id} (#{database})."
exec(*ARGV)
