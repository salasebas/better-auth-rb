# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.11.1](https://github.com/salasebas/better-auth-rb/compare/better_auth-rails/v0.11.0...better_auth-rails/v0.11.1) (2026-07-23)


### Miscellaneous Chores

* **better_auth-rails:** Synchronize better-auth-release versions

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-rails-v0.10.0...better_auth-rails/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.

### Features

* **adapters:** add atomic storage primitives ([8d715c9](https://github.com/salasebas/better-auth-rb/commit/8d715c92ba2dbd4aa4b167a3319a9ac94c629519))
* **schema:** align migration plugin schema parity ([c0261dc](https://github.com/salasebas/better-auth-rb/commit/c0261dc1e5fd649557cd8a57b92c0609620c3767))
* **schema:** honor plugin migration controls ([#48](https://github.com/salasebas/better-auth-rb/issues/48)) ([c67e8bf](https://github.com/salasebas/better-auth-rb/commit/c67e8bf216a2b5f8ad52f53cb9f56e6cfbfa39bb))


### Bug Fixes

* **adapters:** fail closed on singular updates ([c7cf07f](https://github.com/salasebas/better-auth-rb/commit/c7cf07fe19887d682eb94956617532d840beb018))
* **ci:** resolve Ruby 3.4 lint, plugin loading, and upstream parity ([ecf5edd](https://github.com/salasebas/better-auth-rb/commit/ecf5edd032eb3695e94456754779656fe017cd7b))
* harden client IP rate-limit keys ([#39](https://github.com/salasebas/better-auth-rb/issues/39)) ([cb2fefd](https://github.com/salasebas/better-auth-rb/commit/cb2fefd543ef92f8c2c10fedef7f3bd659a90196))
* **rails:** tag database route specs as integration tests ([4809559](https://github.com/salasebas/better-auth-rb/commit/48095591492faee41c4c8212daaa1e78ceeed692))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))
* **two-factor:** enforce verification attempt limits ([f0a8bf4](https://github.com/salasebas/better-auth-rb/commit/f0a8bf4789e9105191e951452879ab09589f5592))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

## [Unreleased]

### Removed

- Removed the defensive `better_auth_rails` alias gem and compatibility require; use `better_auth-rails` and `require "better_auth/rails"`.

### Fixed

- Honored plugin migration controls in generated Active Record migrations.

## [0.10.0] - 2026-05-21

### Fixed

- Preserved mounted auth responses in Rails apps.
- Improved migration generation, Active Record adapter behavior, routing, and database integration coverage.

## [0.7.0] - 2026-05-05

### Fixed

- Aligned Active Record adapter filtering, joins, falsey values, and lookup semantics with core adapter behavior.
- Hardened controller helper and trusted-origin behavior and passed versioned secrets through Rails configuration.
- Added MySQL and PostgreSQL integration coverage for the adapter changes.

## [0.2.1] - 2026-04-29

### Fixed

- Fixed Active Record adapter value lookup so falsey values are preserved across symbol, string, and storage-key variants.
- Fixed Rails migration generation for JSON and array-like schema fields.

## [0.1.2] - 2026-03-22

### Fixed

- Fixed gemspec files list to use `Dir.glob` instead of `git ls-files` for better CI compatibility
- Fixed dependency constraints for railties and activesupport (now `>= 6.0, < 9`)
- Fixed `better_auth_rails` compatibility gem dependency version

## [0.1.1] - 2026-03-17

### Added

- Initial Rails adapter setup
- Basic gem structure

## [0.1.0] - 2026-03-17

### Added

- Initial project setup
