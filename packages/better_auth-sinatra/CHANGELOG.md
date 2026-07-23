# Changelog

## Unreleased

- Honored plugin migration controls in the Sinatra migration integration.

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-sinatra-v0.10.0...better_auth-sinatra/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.

### Features

* **schema:** align migration plugin schema parity ([c0261dc](https://github.com/salasebas/better-auth-rb/commit/c0261dc1e5fd649557cd8a57b92c0609620c3767))
* **schema:** honor plugin migration controls ([#48](https://github.com/salasebas/better-auth-rb/issues/48)) ([c67e8bf](https://github.com/salasebas/better-auth-rb/commit/c67e8bf216a2b5f8ad52f53cb9f56e6cfbfa39bb))


### Bug Fixes

* **ci:** restore package .ruby-version files for setup-ruby ([c18d220](https://github.com/salasebas/better-auth-rb/commit/c18d220065f3cb7cd2504bef7aa407e2c0c027eb))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))
* **two-factor:** enforce verification attempt limits ([f0a8bf4](https://github.com/salasebas/better-auth-rb/commit/f0a8bf4789e9105191e951452879ab09589f5592))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

## 0.10.0 - 2026-05-21

- Removed obsolete helper wiring and expanded mounted app, migration, and routing coverage.
- Updated Sinatra docs for current mounting and integration behavior.

## 0.7.0 - 2026-05-05

- Fixed auth dispatch when Rack splits mounted paths across `SCRIPT_NAME` and `PATH_INFO`.
- Rejected `better_auth at: "/"` to avoid capturing every Sinatra route.
- Stopped swallowing real migration bookkeeping query errors while preserving empty-state behavior for missing schema tables.
- Split simple single-line multi-statement SQL migration files.
- Passed versioned `secrets` through Sinatra configuration to core auth.
- Warned when `better_auth` is configured more than once on the same Sinatra app class.
- Returned JSON-shaped 401 responses from `require_authentication` when JSON is preferred.
- Removed duplicate Rake task wiring and clarified `better_auth:routes` output.
- Documented mount path, Rack nesting, SQL migration, and helper auth caveats.

## 0.1.1 - 2026-04-29

- Fixed mounted base-path propagation when creating the Sinatra auth instance.
- Fixed session helper request preparation and migration dialect normalization for PostgreSQL and SQLite aliases.

## 0.1.0

- Initial Sinatra adapter.
