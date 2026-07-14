# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Removed

- Removed the defensive `better_auth_rails` alias gem and compatibility require; use `better_auth-rails` and `require "better_auth/rails"`.

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
