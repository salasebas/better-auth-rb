#!/usr/bin/env ruby
# frozen_string_literal: true

module AuditGems
  module_function

  def run(root:)
    status = 0
    root_gemfile = File.join(root, "Gemfile")
    gemfiles = [root_gemfile]
    gemfiles.concat(Dir.glob(File.join(root, "packages", "*/Gemfile")).sort)

    gemfiles.each do |gemfile|
      next unless File.exist?(gemfile)

      puts "Auditing #{gemfile}"
      package_env = {"BUNDLE_GEMFILE" => gemfile}
      unless system(package_env, "bundle", "check", chdir: root) ||
          system(package_env, "bundle", "install", chdir: root)
        warn "Failed to install bundle for #{gemfile}"
        status = 1
        next
      end

      audit_env = {"BUNDLE_GEMFILE" => root_gemfile}
      success = system(
        audit_env,
        "bundle",
        "exec",
        "bundler-audit",
        "check",
        File.dirname(gemfile),
        chdir: root
      )
      status = 1 unless success
    end

    status
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path(ARGV.fetch(0, File.expand_path("..", __dir__)))
  exit AuditGems.run(root: root)
end
