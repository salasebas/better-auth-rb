# frozen_string_literal: true

require_relative "lib/better_auth/mongo_adapter/version"

Gem::Specification.new do |spec|
  spec.name = "better_auth-mongo-adapter"
  spec.version = BetterAuth::MongoAdapter::VERSION
  spec.authors = ["Sebastian Sala"]
  spec.email = ["sebastian.sala.tech@gmail.com"]

  spec.summary = "MongoDB adapter package for Better Auth Ruby"
  spec.description = [
    "Deprecated compatibility package for Better Auth Ruby MongoDB support.",
    "Use the better_auth-mongodb gem and require \"better_auth/mongodb\" instead."
  ].join(" ")
  spec.homepage = "https://github.com/sebasxsala/better-auth-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sebasxsala/better-auth-rb"
  spec.metadata["changelog_uri"] = "https://github.com/sebasxsala/better-auth-rb/blob/main/packages/better_auth-mongo-adapter/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/sebasxsala/better-auth-rb/issues"

  spec.files = Dir.glob("lib/**/*", File::FNM_DOTMATCH).select { |file| File.file?(file) } +
    ["LICENSE.md", "README.md", "CHANGELOG.md"].select { |file| File.exist?(file) }
  spec.require_paths = ["lib"]

  spec.add_dependency "better_auth-mongodb", BetterAuth::MongoAdapter::VERSION

  spec.add_development_dependency "bundler", "~> 2.5"
  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "rake", "~> 13.2"
  spec.add_development_dependency "standardrb", "~> 1.0"
  spec.add_development_dependency "simplecov", "~> 0.22"
end
