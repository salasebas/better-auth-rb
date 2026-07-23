# Changelog

## Unreleased

- Honored plugin migration controls in the Grape migration integration.

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-grape-v0.10.0...better_auth-grape/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.

### Features

* **schema:** align migration plugin schema parity ([c0261dc](https://github.com/salasebas/better-auth-rb/commit/c0261dc1e5fd649557cd8a57b92c0609620c3767))
* **schema:** honor plugin migration controls ([#48](https://github.com/salasebas/better-auth-rb/issues/48)) ([c67e8bf](https://github.com/salasebas/better-auth-rb/commit/c67e8bf216a2b5f8ad52f53cb9f56e6cfbfa39bb))


### Bug Fixes

* **ci:** restore package .ruby-version files for setup-ruby ([c18d220](https://github.com/salasebas/better-auth-rb/commit/c18d220065f3cb7cd2504bef7aa407e2c0c027eb))
* **grape:** support structured version options ([d40e2c4](https://github.com/salasebas/better-auth-rb/commit/d40e2c4fde44fb1b03b2bf93ba4263538c1c973b))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))
* **two-factor:** enforce verification attempt limits ([f0a8bf4](https://github.com/salasebas/better-auth-rb/commit/f0a8bf4789e9105191e951452879ab09589f5592))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

## 0.10.0

- Improved cookie handling for mounted Grape apps.
- Added migration planning support and broader integration coverage.

## 0.8.0

- Initial Grape integration package.
