# frozen_string_literal: true

# Workspace Gemfile - Better Auth Ruby Monorepo
# This Gemfile supports local development across all packages.

source "https://rubygems.org"

ruby file: "packages/better_auth/.ruby-version"

# Local package references for development.
# This allows working on all packages simultaneously.
gem "better_auth", path: "packages/better_auth"
gem "better_auth-redis-storage", path: "packages/better_auth-redis-storage"
gem "better_auth-api-key", path: "packages/better_auth-api-key"
gem "better_auth-passkey", path: "packages/better_auth-passkey"
gem "better_auth-stripe", path: "packages/better_auth-stripe"
gem "better_auth-mongodb", path: "packages/better_auth-mongodb"
gem "better_auth-mongo-adapter", path: "packages/better_auth-mongo-adapter"
gem "better_auth-oauth-provider", path: "packages/better_auth-oauth-provider"
gem "better_auth-scim", path: "packages/better_auth-scim"
gem "better_auth-oidc", path: "packages/better_auth-oidc"
gem "better_auth-saml", path: "packages/better_auth-saml"
gem "better_auth-sso", path: "packages/better_auth-sso"
gem "better_auth-telemetry", path: "packages/better_auth-telemetry"
gem "better_auth-rails", path: "packages/better_auth-rails"
gem "better_auth-roda", path: "packages/better_auth-roda"
gem "better_auth-sinatra", path: "packages/better_auth-sinatra"
gem "better_auth-hanami", path: "packages/better_auth-hanami"
gem "better_auth-grape", path: "packages/better_auth-grape"
gem "better_auth-cli", path: "packages/better_auth-cli"

# Workspace development dependencies.
group :development, :test do
  # Linting
  gem "standardrb", "~> 1.0"

  # Testing dependencies used by the packages.
  gem "minitest", "~> 5.25"
  gem "rspec", "~> 3.13"
  gem "pg", "~> 1.5"
  gem "mysql2", "~> 0.5"
  gem "sqlite3", "~> 2.0"
  gem "sequel", "~> 5.83"
  gem "hanami", ">= 2.3", "< 2.4"
  gem "hanami-router", ">= 2.3", "< 3"
  gem "grape", ">= 3.0", "< 4"
  gem "rom-sql", ">= 3.7", "< 4"
  gem "roda", ">= 3.0", "< 4"
  gem "tiny_tds", "~> 2.1"

  # Git hooks
  gem "lefthook", "~> 1.11", require: false

  # Security audit
  gem "bundler-audit", require: false

  # Build tasks
  gem "rake", "~> 13.2"

  # Coverage
  gem "simplecov", "~> 0.22", require: false
end
