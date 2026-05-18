# frozen_string_literal: true

require_relative "lib/better_auth/rails/version"

Gem::Specification.new do |spec|
  spec.name = "better_auth_rails"
  spec.version = BetterAuth::Rails::VERSION
  spec.authors = ["Sebastian Sala"]
  spec.email = ["sebastian.sala.tech@gmail.com"]

  spec.summary = "Alias for better_auth-rails"
  spec.description = [
    "Compatibility alias for better_auth-rails, the Rails integration for Better Auth Ruby.",
    "Better Auth Ruby is independent and not affiliated with, maintained by, or endorsed by the Better Auth project."
  ].join(" ")
  spec.homepage = "https://github.com/sebasxsala/better-auth-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sebasxsala/better-auth-rb"
  spec.metadata["bug_tracker_uri"] = "https://github.com/sebasxsala/better-auth-rb/issues"

  spec.files = [
    "lib/better_auth_rails.rb",
    "LICENSE.md"
  ]
  spec.require_paths = ["lib"]

  spec.add_dependency "better_auth-rails", BetterAuth::Rails::VERSION
end
