# frozen_string_literal: true

require_relative "lib/better_auth/mongodb/version"

Gem::Specification.new do |spec|
  spec.name = "better_auth-mongodb"
  spec.version = BetterAuth::MongoDB::VERSION
  spec.authors = ["Sebastian Sala"]
  spec.email = ["sebastian.sala.tech@gmail.com"]

  spec.summary = "MongoDB adapter package for Better Auth Ruby"
  spec.description = [
    "Adds a MongoDB database adapter for Better Auth Ruby.",
    "Better Auth Ruby is an independent modern authentication framework for Ruby inspired by Better Auth.",
    "Keeps MongoDB dependencies out of the core gem."
  ].join(" ")
  spec.homepage = "https://github.com/sebasxsala/better-auth-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sebasxsala/better-auth-rb"
  spec.metadata["changelog_uri"] = "https://github.com/sebasxsala/better-auth-rb/blob/main/packages/better_auth-mongodb/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/sebasxsala/better-auth-rb/issues"

  spec.files = Dir.glob("lib/**/*", File::FNM_DOTMATCH).select { |file| File.file?(file) } +
    ["README.md", "CHANGELOG.md", "LICENSE.md"].select { |f| File.exist?(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "better_auth", "~> 0.1"
  spec.add_dependency "bigdecimal", ">= 3.1", "< 5.0"
  spec.add_dependency "logger", ">= 1.6", "< 2.0"
  spec.add_dependency "mongo", "~> 2.21"

  spec.add_development_dependency "bundler", "~> 2.5"
  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "rake", "~> 13.2"
  spec.add_development_dependency "standardrb", "~> 1.0"
  spec.add_development_dependency "simplecov", "~> 0.22"
end
