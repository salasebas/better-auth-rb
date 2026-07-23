# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.11.1](https://github.com/salasebas/better-auth-rb/compare/better_auth-hanami/v0.11.0...better_auth-hanami/v0.11.1) (2026-07-23)


### Miscellaneous Chores

* **better_auth-hanami:** Synchronize better-auth-release versions

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-hanami-v0.10.0...better_auth-hanami/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.

### Features

* **adapters:** add atomic storage primitives ([8d715c9](https://github.com/salasebas/better-auth-rb/commit/8d715c92ba2dbd4aa4b167a3319a9ac94c629519))
* **schema:** align migration plugin schema parity ([c0261dc](https://github.com/salasebas/better-auth-rb/commit/c0261dc1e5fd649557cd8a57b92c0609620c3767))
* **schema:** honor plugin migration controls ([#48](https://github.com/salasebas/better-auth-rb/issues/48)) ([c67e8bf](https://github.com/salasebas/better-auth-rb/commit/c67e8bf216a2b5f8ad52f53cb9f56e6cfbfa39bb))


### Bug Fixes

* **adapters:** fail closed on singular updates ([c7cf07f](https://github.com/salasebas/better-auth-rb/commit/c7cf07fe19887d682eb94956617532d840beb018))
* **ci:** restore package .ruby-version files for setup-ruby ([c18d220](https://github.com/salasebas/better-auth-rb/commit/c18d220065f3cb7cd2504bef7aa407e2c0c027eb))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))
* **two-factor:** enforce verification attempt limits ([f0a8bf4](https://github.com/salasebas/better-auth-rb/commit/f0a8bf4789e9105191e951452879ab09589f5592))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

## [Unreleased]

### Fixed

- Honored plugin migration controls in generated Hanami migrations.

## [0.10.0] - 2026-05-21

### Fixed

- Preserved migration foreign keys and improved generated migration output.
- Hardened Hanami routing, helpers, rate limits, rake tasks, and Sequel adapter behavior.

## [0.7.0] - 2026-05-05

### Fixed

- Aligned Hanami route mounting, action helpers, install generator, and migration generator behavior with the shared Rack and schema semantics.
- Hardened the Sequel adapter for upstream-shaped filtering, joins, falsey values, and limit behavior.

## [0.1.1] - 2026-04-29

### Fixed

- Fixed Hanami route installation to require the public adapter entrypoint and avoid duplicating route configuration.
- Fixed mounted app path handling, migration type mapping for JSON, arrays, and big integers, and Sequel adapter lookup of falsey values.

## [0.1.0] - 2026-04-28

### Added

- Initial Hanami 2.3+ adapter with Rack route mounting, Sequel persistence, ROM::SQL migration rendering, action helpers, and Rake/generator commands.
