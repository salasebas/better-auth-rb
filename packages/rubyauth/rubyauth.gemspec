# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rubyauth"
  spec.version = "0.10.0"
  spec.authors = ["Sebastian Sala"]
  spec.email = ["sebastian.sala.tech@gmail.com"]

  spec.summary = "Alias package for Better Auth Ruby"
  spec.description = [
    "RubyAuth is an alias package that installs better_auth.",
    "Use Better Auth Ruby documentation for the canonical API."
  ].join(" ")
  spec.homepage = "https://better-auth-rb.vercel.app/"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sebasxsala/better-auth-rb"
  spec.metadata["bug_tracker_uri"] = "https://github.com/sebasxsala/better-auth-rb/issues"

  spec.files = Dir.glob("lib/**/*", File::FNM_DOTMATCH).select { |file| File.file?(file) } +
    ["README.md", "CHANGELOG.md", "LICENSE.md"].select { |f| File.exist?(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "better_auth", "0.10.0"
end
