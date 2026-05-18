# Grape Adapter

**Status:** Initial Grape adapter implemented with Rack mounting, request helpers, SQL migration tasks, and docs.

**Upstream Reference:** Better Auth upstream exposes framework adapters as thin wrappers around the same auth handler. The Ruby Grape adapter follows the existing Rack/Rails/Sinatra/Hanami shape by mounting the core `BetterAuth.auth` Rack object instead of reimplementing auth routes in Grape endpoints.

## Ruby/Grape Adaptation

Grape integration provides:

- `BetterAuth::Grape.configure` and `BetterAuth::Grape.auth` for building the core auth instance from app configuration.
- `include BetterAuth::Grape` and `better_auth at: "/api/auth"` for mounting the core Rack auth app inside a `Grape::API` class.
- Helpers: `current_session`, `current_user`, `authenticated?`, and `require_authentication`.
- SQL migration Rake tasks: `better_auth:install`, `better_auth:generate:migration`, `better_auth:migrate`, and `better_auth:routes`.
- Prefix-aware mounting for APIs that use `prefix :api` or `version "v1", using: :path`; passing `at: "/auth"` mounts at `/api/auth` or `/api/v1/auth` respectively.

The adapter keeps all auth behavior in `packages/better_auth`. Grape code only adapts configuration, mounting, helper ergonomics, and SQL migration workflow.

Grape mounting handles direct requests under the auth mount, Rack `SCRIPT_NAME`/`PATH_INFO` splits, nested Rack mounts, plugin endpoints, server-only endpoint blocking, origin/fetch-metadata checks, and unexpected endpoint errors through the same `on_api_error` policy used by the Rails mount wrapper.

## Database Notes

Grape has no built-in database adapter or universal migration command. The first Better Auth Grape integration therefore uses the existing core SQL adapters and a shared SQL migration renderer/runner. Generated migrations live under `db/better_auth/migrate` and are tracked through a `better_auth_schema_migrations` table.

Unsupported migration targets:

- memory adapter;
- MongoDB adapter;
- custom adapters that do not expose `connection` and `dialect`;
- app-specific ORM migrations, which should be managed by the host application.

## Verification

```bash
cd /Users/sebastiansala/projects/better-auth/packages/better_auth-grape
rbenv exec bundle exec rspec
RUBOCOP_CACHE_ROOT=/private/var/folders/7x/jrsz946d2w73n42fb1_ff5000000gn/T/rubocop_cache_grape rbenv exec bundle exec standardrb
```
