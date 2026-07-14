# frozen_string_literal: true

require_relative "lib/better_auth/version"

Gem::Specification.new do |spec|
  spec.name = "better_auth"
  spec.version = BetterAuth::VERSION
  spec.authors = ["Sebastian Sala"]
  spec.email = ["sebastian.sala.tech@gmail.com"]

  spec.summary = "Comprehensive authentication framework for Ruby/Rack"
  spec.description = [
    "Better Auth Ruby is an independent, modern authentication framework for Ruby, inspired by Better Auth.",
    "It is not affiliated with, maintained by, or endorsed by the Better Auth project.",
    "It provides a framework-agnostic Rack core, auth routes, sessions, adapters, and a plugin system."
  ].join(" ")
  spec.homepage = "https://github.com/sebasxsala/better-auth-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sebasxsala/better-auth-rb"
  spec.metadata["changelog_uri"] = "https://github.com/sebasxsala/better-auth-rb/blob/main/packages/better_auth/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/sebasxsala/better-auth-rb/issues"

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir.glob("lib/**/*", File::FNM_DOTMATCH).select { |f| File.file?(f) } +
    ["README.md", "CHANGELOG.md", "LICENSE.md"].select { |f| File.exist?(f) }
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Core runtime dependencies
  spec.add_dependency "base64", ">= 0.2", "< 1.0"
  spec.add_dependency "rack", "~> 3.0"
  spec.add_dependency "json", "~> 2.0"
  spec.add_dependency "jwt", "~> 2.8"
  spec.add_dependency "jwe", "~> 1.1", ">= 1.1.1"

  # Development dependencies
  spec.add_development_dependency "bundler", "~> 2.5"
  spec.add_development_dependency "bcrypt", "~> 3.1"
  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "standardrb", "~> 1.0"
  spec.add_development_dependency "rake", "~> 13.2"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "pg", "~> 1.5"
  spec.add_development_dependency "mysql2", "~> 0.5"
  spec.add_development_dependency "sqlite3", "~> 2.0"
  spec.add_development_dependency "sequel", "~> 5.83"
  spec.add_development_dependency "tiny_tds", "~> 2.1"
end
