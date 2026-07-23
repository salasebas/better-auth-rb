# Changelog

## Unreleased

## [0.11.1](https://github.com/salasebas/better-auth-rb/compare/better_auth-roda/v0.11.0...better_auth-roda/v0.11.1) (2026-07-23)


### Miscellaneous Chores

* **better_auth-roda:** Synchronize better-auth-release versions

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-roda-v0.10.0...better_auth-roda/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.

### Bug Fixes

* **ci:** restore package .ruby-version files for setup-ruby ([c18d220](https://github.com/salasebas/better-auth-rb/commit/c18d220065f3cb7cd2504bef7aa407e2c0c027eb))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

## 0.10.0 - 2026-05-21

- Initial Roda integration package.
- Fixed nested auth mount handling and expanded plugin, configuration, and migration coverage.
