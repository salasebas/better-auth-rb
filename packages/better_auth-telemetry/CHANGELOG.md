# Changelog

## 0.10.0

- Improved database detection, including MongoDB adapter metadata.
- Updated telemetry docs for the current package set.

## 0.8.0

- Initial release. Ports the upstream `@better-auth/telemetry` package
  (vendored at `upstream/better-auth/1.6.9/packages/telemetry/`) into the
  Ruby monorepo as the canonical `better_auth-telemetry` gem with a paired
  `openauth-telemetry` alias.
- Opt-in only. Telemetry is disabled by default and skipped under
  `RACK_ENV=test` / `RAILS_ENV=test` / `APP_ENV=test` unless
  `context[:skip_test_check]` bypasses the gate.
- Supports both the `BETTER_AUTH_*` and `OPEN_AUTH_*` environment-variable
  prefixes for `BETTER_AUTH_TELEMETRY`, `BETTER_AUTH_TELEMETRY_DEBUG`, and
  `BETTER_AUTH_TELEMETRY_ENDPOINT` via `BetterAuth::Env.get`.
- HTTP delivery uses Ruby's standard library (`Net::HTTP`) with a 5-second
  open + read timeout. No external HTTP-client gem is required at runtime.
- Soft-loaded by `BetterAuth::Auth#initialize`: when bundled, `auth.telemetry`
  returns a publisher; when not bundled, it returns a noop publisher whose
  `#publish` is a safe no-op.
- Mirrors upstream redaction rules and camelCase wire-format keys for
  `payload.config`. Ruby-specific deviations (single Ruby implementation,
  `runtime.engine` extra key, `cpuSpeed` omitted, `cpuModel` always `nil`,
  `packageManager` reflects Bundler, framework/database probe lists,
  `appName` not emitted) are documented in the README.
- No file under `upstream/better-auth/1.6.9/` is modified.
