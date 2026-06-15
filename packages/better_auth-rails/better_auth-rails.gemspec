# frozen_string_literal: true

ROOT_LICENSE = File.expand_path("../../LICENSE.md", __dir__)

require_relative "lib/better_auth/rails/version"

Gem::Specification.new do |spec|
  spec.name = "better_auth-rails"
  spec.version = BetterAuth::Rails::VERSION
  spec.authors = ["Sebastian Sala"]
  spec.email = ["sebastian.sala.tech@gmail.com"]

  spec.summary = "Rails adapter for Better Auth"
  spec.description = [
    "Rails integration for Better Auth Ruby.",
    "Better Auth Ruby is an independent modern authentication framework for Ruby inspired by Better Auth.",
    "Provides middleware, controller helpers, and generators."
  ].join(" ")
  spec.homepage = "https://github.com/sebasxsala/better-auth-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sebasxsala/better-auth-rb"
  spec.metadata["changelog_uri"] = "https://github.com/sebasxsala/better-auth-rb/blob/main/packages/better_auth-rails/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/sebasxsala/better-auth-rb/issues"

  spec.files = Dir.glob("lib/**/*", File::FNM_DOTMATCH).select { |f| File.file?(f) } +
    ["README.md", "CHANGELOG.md"].select { |f| File.exist?(f) } + (File.exist?(ROOT_LICENSE) ? [ROOT_LICENSE] : [])
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "better_auth", "~> 0.1"
  spec.add_dependency "railties", ">= 6.0", "< 9"
  spec.add_dependency "activesupport", ">= 6.0", "< 9"
  spec.add_dependency "activerecord", ">= 6.0", "< 9"

  # Development dependencies
  spec.add_development_dependency "bundler", "~> 2.5"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "standardrb", "~> 1.0"
  spec.add_development_dependency "rake", "~> 13.2"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "pg", "~> 1.5"
  spec.add_development_dependency "mysql2", "~> 0.5"
  spec.add_development_dependency "better_auth-passkey", "~> 0.8"
end
