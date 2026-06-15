#!/usr/bin/env ruby
# frozen_string_literal: true

ROOT = File.expand_path("..", __dir__)
status = 0

gemfiles = [File.join(ROOT, "Gemfile")]
gemfiles.concat(Dir.glob(File.join(ROOT, "packages", "*/Gemfile")).sort)

gemfiles.each do |gemfile|
  next unless File.exist?(gemfile)

  puts "Auditing #{gemfile}"
  env = {"BUNDLE_GEMFILE" => gemfile}
  unless system(env, "bundle", "check", chdir: ROOT) ||
      system(env, "bundle", "install", chdir: ROOT)
    warn "Failed to install bundle for #{gemfile}"
    status = 1
    next
  end

  success = system(env, "bundle", "exec", "bundler-audit", "check", chdir: ROOT)
  status = 1 unless success
end

exit status
