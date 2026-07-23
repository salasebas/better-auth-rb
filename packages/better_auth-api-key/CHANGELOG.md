# Changelog

## Unreleased

- Hardened API-key verification and counter updates where authoritative adapter
  operations are available, with regression coverage for stale-write cases.
- Added a checked upstream test inventory for this plugin's pinned reference
  files.

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-api-key-v0.10.0...better_auth-api-key/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.

### Features

* **schema:** align migration plugin schema parity ([c0261dc](https://github.com/salasebas/better-auth-rb/commit/c0261dc1e5fd649557cd8a57b92c0609620c3767))


### Bug Fixes

* **api-key:** load access plugin before permission checks ([985e56c](https://github.com/salasebas/better-auth-rb/commit/985e56cdc29298aac995ff7d0f04a7f1bf13a7cd))
* **api-key:** make verification counters authoritative ([6550ae7](https://github.com/salasebas/better-auth-rb/commit/6550ae753f104f771e313360f56e6fdcff82d005))
* **ci:** restore package .ruby-version files for setup-ruby ([c18d220](https://github.com/salasebas/better-auth-rb/commit/c18d220065f3cb7cd2504bef7aa407e2c0c027eb))
* load external plugin gems without stub recursion ([4926bae](https://github.com/salasebas/better-auth-rb/commit/4926bae7520c17438de25e99cb2155839c177493))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

## 0.10.0 - 2026-05-21

- Improved adapter coverage and Redis-backed storage behavior for API key flows.
- Tightened API key listing behavior so responses stay consistent across supported adapters.

## 0.7.0 - 2026-05-05

- Changed API-key-backed sessions to expose `tokenFingerprint` instead of storing the raw API key in `session["token"]`.
- Hardened API key listing and expired-key cleanup behavior.
- Improved API key metadata handling and added regression coverage for session fingerprint behavior.

## 0.2.1 - 2026-04-30

- Fixed API key metadata normalization so symbol and string metadata keys preserve nested metadata payloads.
- Added upstream parity coverage for API key behavior and error-code response details.

## 0.2.0 - 2026-04-29

- Aligned API key behavior with upstream Better Auth v1.6.9, including key verification, permission checks, metadata updates, expiration, rate limiting, prefix handling, and route response shapes.
- Expanded package documentation and executable coverage for upstream API key edge cases.

## 0.1.0

- Extract API key support into the `better_auth-api-key` package.
