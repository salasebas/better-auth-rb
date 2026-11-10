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

def git(*args)
  output = IO.popen(["git", "-C", ROOT, *args], &:read)
  abort "git #{args.join(" ")} failed." unless $?.success?
  output
end

def with_clone_registry
  common_dir = git("rev-parse", "--path-format=absolute", "--git-common-dir").strip
  path = File.join(common_dir, "better-auth-test-databases-#{generated_worktree_id(common_dir)}")
  File.open(path, File::RDWR | File::CREAT) do |file|
    file.flock(File::LOCK_EX)
    yield file
  end
end

def register_worktree_id(id)
  with_clone_registry do |file|
    file.puts(id) unless file.each_line(chomp: true).include?(id)
  end
end

def live_worktree_ids
  paths = git("worktree", "list", "--porcelain").scan(/^worktree (.+)$/).flatten.select { |path| File.exist?(path) }
  ids = paths.map { |path| generated_worktree_id(path) }
  abort "git worktree list did not include this worktree (#{ROOT})." unless ids.include?(generated_worktree_id(ROOT))
  ids
end

def prune(dry_run:)
  with_clone_registry do |file|
    live_ids = live_worktree_ids
    stale_ids, kept_ids = file.each_line(chomp: true).uniq.partition { |id| !live_ids.include?(id) }
    return if stale_ids.empty?

    PRUNABLE.each do |service, (client, list, drop)|
      names = compose_exec(service, client, list).split("\n").map(&:strip)
      names.select { |name| stale_ids.any? { |id| name.end_with?("_#{id}") } }.each do |name|
        if dry_run
          puts "Would drop #{service} database #{name}"
        else
          compose_exec(service, client, drop.call(name))
          puts "Dropped #{service} database #{name}"
        end
      end
    end
    return if dry_run

    file.rewind
    file.truncate(0)
    file.write(kept_ids.map { |id| "#{id}\n" }.join)
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

if ENV.fetch(TestDatabases::WORKTREE_ID_ENV, "").empty?
  ENV[TestDatabases::WORKTREE_ID_ENV] = generated_worktree_id(ROOT)
  register_worktree_id(TestDatabases.worktree_id)
else
  warn "#{TestDatabases::WORKTREE_ID_ENV} is preset, so --prune will never drop these databases."
end
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
