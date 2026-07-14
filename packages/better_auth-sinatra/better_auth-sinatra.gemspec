# frozen_string_literal: true

require_relative "lib/better_auth/sinatra/version"

Gem::Specification.new do |spec|
  spec.name = "better_auth-sinatra"
  spec.version = BetterAuth::Sinatra::VERSION
  spec.authors = ["Sebastian Sala"]
  spec.email = ["sebastian.sala.tech@gmail.com"]

  spec.summary = "Sinatra adapter for Better Auth"
  spec.description = [
    "Sinatra integration for Better Auth Ruby.",
    "Better Auth Ruby is an independent modern authentication framework for Ruby inspired by Better Auth.",
    "Provides mounting helpers, request helpers, and SQL migration tasks."
  ].join(" ")
  spec.homepage = "https://github.com/sebasxsala/better-auth-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sebasxsala/better-auth-rb"
  spec.metadata["changelog_uri"] = "https://github.com/sebasxsala/better-auth-rb/blob/main/packages/better_auth-sinatra/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/sebasxsala/better-auth-rb/issues"

  spec.files = Dir.glob("lib/**/*", File::FNM_DOTMATCH).select { |f| File.file?(f) } +
    ["README.md", "CHANGELOG.md", "LICENSE.md"].select { |f| File.exist?(f) }
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "better_auth", "~> 0.1"
  spec.add_dependency "sinatra", ">= 3.0", "< 5"

  spec.add_development_dependency "bundler", "~> 2.5"
  spec.add_development_dependency "rack-test", "~> 2.2"
  spec.add_development_dependency "rake", "~> 13.2"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "standardrb", "~> 1.0"
end
