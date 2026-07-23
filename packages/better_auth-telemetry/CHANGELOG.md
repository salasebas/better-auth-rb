# Changelog

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-telemetry-v0.10.0...better_auth-telemetry/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.

### Bug Fixes

* **ci:** resolve Ruby 3.4 lint, plugin loading, and upstream parity ([ecf5edd](https://github.com/salasebas/better-auth-rb/commit/ecf5edd032eb3695e94456754779656fe017cd7b))
* **ci:** restore package .ruby-version files for setup-ruby ([c18d220](https://github.com/salasebas/better-auth-rb/commit/c18d220065f3cb7cd2504bef7aa407e2c0c027eb))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))
* separate canonical and serving origins ([#37](https://github.com/salasebas/better-auth-rb/issues/37)) ([c1bd12e](https://github.com/salasebas/better-auth-rb/commit/c1bd12e81a1cb21a8d0ba186cefd554753e565f6))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

## 0.10.0

- Improved database detection, including MongoDB adapter metadata.
- Updated telemetry docs for the current package set.

## 0.8.0

- Initial release. Ports the upstream `@better-auth/telemetry` package
  (vendored at `reference/upstream-src/1.6.9/repository/packages/telemetry/`) into the
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
- No file under `reference/upstream-src/1.6.9/repository/` is modified.
