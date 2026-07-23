# Changelog

## Unreleased

- Honored plugin migration controls in generated schema and Mongo index
  commands.

## [0.11.1](https://github.com/salasebas/better-auth-rb/compare/better_auth-cli/v0.11.0...better_auth-cli/v0.11.1) (2026-07-23)


### Bug Fixes

* harden release publishing and recovery ([#56](https://github.com/salasebas/better-auth-rb/issues/56)) ([fa502ae](https://github.com/salasebas/better-auth-rb/commit/fa502ae709171560fe5ccb61f2862b2dde259e9a))

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-cli-v0.10.0...better_auth-cli/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.

### Features

* **cli:** add config discovery, secret, and info diagnostics ([e522cf6](https://github.com/salasebas/better-auth-rb/commit/e522cf6755512b465dbf2f2589eb2335db6f1af4))
* **cli:** add init, strict flags, upgrade, and upstream parity ([af2c1ff](https://github.com/salasebas/better-auth-rb/commit/af2c1ff554905d6db66e556352c7bf77f860ed9b))
* **schema:** align migration plugin schema parity ([c0261dc](https://github.com/salasebas/better-auth-rb/commit/c0261dc1e5fd649557cd8a57b92c0609620c3767))
* **schema:** honor plugin migration controls ([#48](https://github.com/salasebas/better-auth-rb/issues/48)) ([c67e8bf](https://github.com/salasebas/better-auth-rb/commit/c67e8bf216a2b5f8ad52f53cb9f56e6cfbfa39bb))


### Bug Fixes

* **ci:** restore package .ruby-version files for setup-ruby ([c18d220](https://github.com/salasebas/better-auth-rb/commit/c18d220065f3cb7cd2504bef7aa407e2c0c027eb))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))
* separate canonical and serving origins ([#37](https://github.com/salasebas/better-auth-rb/issues/37)) ([c1bd12e](https://github.com/salasebas/better-auth-rb/commit/c1bd12e81a1cb21a8d0ba186cefd554753e565f6))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

## 0.10.0

- Improved CLI error handling and expanded command coverage.

## 0.9.0

- Initial Better Auth CLI package with `better-auth generate`, `better-auth migrate`, `better-auth migrate status`, `better-auth doctor`, and `better-auth mongo indexes`.
