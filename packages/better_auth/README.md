<p align="center">
  <h2 align="center">
    Better Auth Ruby
  </h2>

  <p align="center">
    The most comprehensive authentication framework for Ruby
    <br />
    <a href="https://better-auth.com"><strong>Learn more »</strong></a>
    <br />
    <br />
    <a href="https://discord.gg/better-auth">Discord</a>
    ·
    <a href="https://better-auth.com">Website</a>
    ·
    <a href="https://github.com/sebasxsala/better-auth-rb/issues">Issues</a>
  </p>

[![Gem](https://img.shields.io/gem/v/better_auth?style=flat&colorA=000000&colorB=000000)](https://rubygems.org/gems/better_auth)
[![GitHub stars](https://img.shields.io/github/stars/sebasxsala/better-auth?style=flat&colorA=000000&colorB=000000)](https://github.com/sebasxsala/better-auth-rb/stargazers)
</p>

## About the Project

Better Auth Ruby is a comprehensive authentication and authorization library for Ruby. It provides a complete set of features out of the box and includes a plugin ecosystem that simplifies adding advanced functionalities with minimal code.

### Features

- **Framework Agnostic Core**: Works with any Rack-based application
- **Rails Integration**: First-class Rails support with middleware and helpers
- **Session Management**: Secure session handling
- **Multiple Authentication Methods**: Email/password, OAuth, JWT, and more
- **Two-Factor Authentication**: TOTP and WebAuthn support
- **Plugin System**: Extensible architecture for custom features

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'better_auth'
```

And then execute:

```bash
bundle install
```

Or install it yourself as:

```bash
gem install better_auth
```

## Usage

### Basic Setup

```ruby
require 'better_auth'

auth = BetterAuth.auth(
  base_url: ENV.fetch("BETTER_AUTH_URL"),
  secret: ENV.fetch("BETTER_AUTH_SECRET"),
  database: :memory
)
```

In production, token-bearing email links require either a static `base_url`
(including `BETTER_AUTH_URL`) or a dynamic `base_url` with `allowed_hosts`.
Request-host inference remains available for other routes and in development.
Legacy deployments can opt out with
`advanced: { allow_unsafe_token_link_base_url_inference: true }`, but doing so
allows request headers to select the origin used in security-token links and is
not recommended.

### Secret Rotation

Better Auth Ruby supports upstream-style non-destructive rotation for encrypted data through versioned secrets. The first entry is used for new encrypted payloads; older entries remain available for decrypting existing data.

```ruby
auth = BetterAuth.auth(
  secret: ENV["BETTER_AUTH_SECRET"], # legacy fallback for older encrypted data
  secrets: [
    { version: 2, value: ENV.fetch("BETTER_AUTH_SECRET_V2") },
    { version: 1, value: ENV.fetch("BETTER_AUTH_SECRET_V1") }
  ],
  database: :memory
)
```

You can also configure the same list via `BETTER_AUTH_SECRETS`:

```bash
BETTER_AUTH_SECRETS="2:new-secret-base64,1:old-secret-base64"
BETTER_AUTH_SECRET="legacy-secret-for-pre-rotation-data"
```

Signed cookies and HMAC/JWT signatures continue to use the current `secret`, matching upstream Better Auth behavior.

### Password Hashing

Better Auth Ruby uses upstream-compatible `scrypt` password hashes by default through Ruby's `OpenSSL::KDF.scrypt`, so no extra password-hashing gem is required for the default setup.

```ruby
auth = BetterAuth.auth(
  secret: ENV.fetch("BETTER_AUTH_SECRET"),
  password_hasher: :scrypt # default
)
```

Applications that prefer Ruby's familiar BCrypt ecosystem can opt in by adding `gem "bcrypt"` and configuring:

```ruby
auth = BetterAuth.auth(
  secret: ENV.fetch("BETTER_AUTH_SECRET"),
  password_hasher: :bcrypt
)
```

Custom Better Auth-style password callbacks are still supported through `email_and_password[:password][:hash]` and `[:verify]`.

### Database Adapters

The core gem ships framework-agnostic adapters for memory, PostgreSQL, MySQL, SQLite, and MSSQL. Driver gems are loaded only when their adapter is instantiated. MongoDB support lives in the external `better_auth-mongodb` package so apps that do not use MongoDB do not install the Mongo driver.

```ruby
auth = BetterAuth.auth(
  secret: ENV.fetch("BETTER_AUTH_SECRET"),
  database: BetterAuth::Adapters::SQLite.new(path: "storage/auth.sqlite3")
)
```

```ruby
require "better_auth/mongodb"

auth = BetterAuth.auth(
  secret: ENV.fetch("BETTER_AUTH_SECRET"),
  database: BetterAuth::Adapters::MongoDB.new(
    database: mongo_client.database,
    client: mongo_client,
    transaction: false
  )
)
```

```ruby
auth = BetterAuth.auth(
  secret: ENV.fetch("BETTER_AUTH_SECRET"),
  database: BetterAuth::Adapters::MSSQL.new(url: ENV.fetch("DATABASE_URL"))
)
```

Custom adapters must implement
`create_if_absent(model:, data:, conflict_field: "id", force_allow_id: true)`
as a targeted first-writer-wins insert returning a boolean,
`consume_one(model:, where:)` as an atomic
delete-and-return of at most one row, and
`increment_one(model:, where:, increment:, set: nil)` as an atomic guarded
numeric update returning the resulting row or `nil`. Concurrent consumers of
one row must have exactly one winner; increments must apply every signed delta
without lost updates. `transaction` must open a real transaction and reuse its
active adapter for nested calls. The base class's compatibility yield is
explicitly non-atomic and must not back either primitive.
Only mutable schema fields declared with `type: "number"` may be incremented;
IDs and string, boolean, date, array, immutable, or unknown fields are rejected.
The base adapter intentionally has no check-then-create fallback.

### Social Providers

```ruby
require "better_auth"

auth = BetterAuth.auth(
  secret: ENV.fetch("BETTER_AUTH_SECRET"),
  social_providers: {
    google: BetterAuth::SocialProviders.google(
      client_id: ENV.fetch("GOOGLE_CLIENT_ID"),
      client_secret: ENV.fetch("GOOGLE_CLIENT_SECRET")
    ),
    github: BetterAuth::SocialProviders.github(
      client_id: ENV.fetch("GITHUB_CLIENT_ID"),
      client_secret: ENV.fetch("GITHUB_CLIENT_SECRET")
    )
  }
)
```

### i18n

Translate server error messages by locale. This plugin is server-side only: clients receive translated error JSON from the existing HTTP routes, and there is no Ruby browser client plugin.

```ruby
auth = BetterAuth.auth(
  secret: ENV.fetch("BETTER_AUTH_SECRET"),
  database: :memory,
  plugins: [
    BetterAuth::Plugins.i18n(
      translations: {
        "fr" => {
          "INVALID_EMAIL_OR_PASSWORD" => "Identifiants invalides"
        }
      },
      detection: ["cookie", "header"],
      locale_cookie: "lang"
    )
  ]
)
```

### Organizations

The organization plugin supports upstream-style organizations, members,
invitations, teams, roles, membership limits, and organization lifecycle hooks.
Ruby option and hook names use snake_case.

```ruby
auth = BetterAuth.auth(
  secret: ENV.fetch("BETTER_AUTH_SECRET"),
  database: :memory,
  plugins: [
    BetterAuth::Plugins.organization(
      membership_limit: 25,
      disable_organization_deletion: true,
      organization_hooks: {
        before_update_organization: ->(data, _ctx) { { data: { name: data[:organization][:name].strip } } },
        after_add_member: ->(data, _ctx) { Audit.log("member added", data[:member]) }
      }
    )
  ]
)
```

Direct member adds and invitation acceptance enforce `membership_limit`.
Deleting or leaving the active organization clears the active organization and
team session fields.

### JavaScript Client

Ruby Better Auth exposes the same HTTP route surface. Frontend apps should use the upstream Better Auth JavaScript client and point it at the Ruby server:

```ts
import { createAuthClient } from "better-auth/client";

export const authClient = createAuthClient({
  baseURL: "http://localhost:3000",
  basePath: "/api/auth",
});
```

### Rails Integration

Add to your Gemfile:

```ruby
gem "better_auth-rails"
```

Then in your ApplicationController:

```ruby
class ApplicationController < ActionController::Base
  include BetterAuth::Rails::ControllerHelpers
end
```

Now you have access to `current_user` and authentication methods:

```ruby
class PostsController < ApplicationController
  before_action :require_authentication

  def index
    @posts = current_user.posts
  end
end
```

## Development

Full documentation is being adapted in the root [`docs-site/`](../../docs-site/README.md) app. Start with the Ruby-first installation, basic usage, Rack, Rails, PostgreSQL, and MySQL pages there; pages with a Ruby port warning still contain upstream TypeScript examples for reference.

### Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/sebasxsala/better-auth-rb.git
cd better-auth/packages/better_auth

# 2. Install dependencies
make install
# or: bundle install

# 3. Run tests to verify everything works
make ci
```

### Common Make Commands

We use a **Makefile** to simplify commands. All have explanatory comments:

```bash
# View all available commands with description
make help

# Development
make console          # Interactive console with gem loaded
make lint            # Check code style
make lint-fix        # Auto-fix style issues

# Testing
make test            # Run all tests
make test-core       # Only core tests (Minitest)
make test-coverage   # Tests with coverage
make ci              # Full CI (lint + test)

# Databases for testing
make db-up           # Start PostgreSQL, MySQL, MongoDB, MSSQL, Redis
make db-down         # Stop containers
```

### Branch Workflow

Development happens on `main`. Create feature branches from `main` and open PRs
back to `main`.

```bash
git checkout main
git pull origin main
git checkout -b feat/new-feature
# ... work ...
git push origin feat/new-feature
```

### How CI/CD Works

**Pull Requests:**
- Each PR runs: lint + tests on Ruby 3.2 and 3.3
- Everything must pass before merging

**Manual Release:**

Releases are published manually with `gem build` and `gem push`. See `RELEASING.md`
at the repository root for the full process.

```bash
# STEP 1: Update the target package version file
# Example: VERSION = "0.1.1"
# Or update .release.yml and run: rake release:sync_versions

# STEP 2: Commit and push to main
git add lib/better_auth/version.rb
git commit -m "chore: bump version to 0.1.1"
git push origin main

# STEP 3: Build and publish
cd packages/better_auth
gem build better_auth.gemspec
gem push better_auth-0.1.1.gem

# STEP 4: Tag the release
git tag better_auth-v0.1.1
git push origin better_auth-v0.1.1
```

Use `better_auth-vX.Y.Z` for the core gem, `better_auth-rails-vX.Y.Z` for Rails, `better_auth-sinatra-vX.Y.Z` for Sinatra, and `better_auth-hanami-vX.Y.Z` for Hanami.

**Local packaging dry-run:**

```bash
make release-check
```

### Manual Release (per package)

```bash
# 1. Update version.rb (or sync from .release.yml)
# 2. Build the gem
gem build better_auth.gemspec

# 3. Publish (you need to be logged into RubyGems)
gem push better_auth-*.gem

# 4. Create and push the tag
git tag -a better_auth-v0.1.1 -m "Release better_auth v0.1.1"
git push origin better_auth-v0.1.1
```

### Project Structure

```
lib/
  better_auth.rb              # Entry point
  better_auth/
    version.rb                # Gem version
    core.rb                   # Core loader
    core/                     # Core logic (framework-agnostic)

test/                       # Core tests (Minitest)
```

**Conventions:**
- Core: Framework-agnostic, uses Minitest
- All code goes through StandardRB (Ruby style guide)

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/sebasxsala/better-auth-rb. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/sebasxsala/better-auth-rb/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Security

### Canonical and serving origins

`base_url` (or `BETTER_AUTH_URL`) is required and defines the stable canonical
identity of the auth server. RubyAuth never infers that identity from request
headers. For an approved multi-domain deployment, configure full origin
patterns separately:

```ruby
BetterAuth.auth(
  secret: ENV.fetch("BETTER_AUTH_SECRET"),
  base_url: "https://auth.example.com",
  serving_origins: ["https://tenant.example.com", "https://*.preview.example.com"],
  trusted_origins: ["https://frontend.example.com"]
)
```

`serving_origins` may select the request-facing URL used by verification,
password-reset, deletion, and magic-link capabilities. Unknown hosts fall back
to the canonical URL. Serving origins are trusted for CSRF and redirect checks,
but the reverse is intentionally false: a `trusted_origins` entry cannot become
a serving origin or control token-bearing links.

`X-Forwarded-Host` and `X-Forwarded-Proto` are considered only when
`advanced.trusted_proxy_headers` is explicitly `true`, and the resulting origin
must still match `serving_origins`. The former hash/dynamic form of `base_url`
is unsupported; migrate its fallback to `base_url` and its allowlist to full
`serving_origins` patterns.

### Trusted origins

`trusted_origins` is merged with the canonical and serving origins rather than
acting as an adapter-local CORS switch. Configure concrete origins for each
environment and keep browser CORS headers in the host Rack stack or reverse proxy. See
[`host-app-responsibilities.md`](../../.docs/features/host-app-responsibilities.md)
for the boundary between origin validation, CORS, and CSRF ownership.

If you discover a security vulnerability within Better Auth Ruby, please send an e-mail to [security@openparcel.dev](mailto:security@openparcel.dev).

All reports will be promptly addressed, and you'll be credited accordingly.
