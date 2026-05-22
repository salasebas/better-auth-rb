# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
