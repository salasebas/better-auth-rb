#!/usr/bin/env ruby
# frozen_string_literal: true

ROOT = File.expand_path("..", __dir__)
status = 0

gemfiles = [File.join(ROOT, "Gemfile")]
gemfiles.concat(Dir.glob(File.join(ROOT, "packages", "*/Gemfile")).sort)

gemfiles.each do |gemfile|
  directory = File.dirname(gemfile)
  lockfile = File.join(directory, "Gemfile.lock")
  next unless File.exist?(lockfile)

  puts "Auditing #{lockfile}"
  unless system({"BUNDLE_GEMFILE" => gemfile}, "bundle", "check", chdir: ROOT) ||
      system({"BUNDLE_GEMFILE" => gemfile}, "bundle", "install", chdir: ROOT)
    warn "Failed to install bundle for #{gemfile}"
    status = 1
    next
  end

  success = system({"BUNDLE_GEMFILE" => gemfile}, "bundle", "exec", "bundler-audit", "check", chdir: ROOT)
  status = 1 unless success
end

exit status
