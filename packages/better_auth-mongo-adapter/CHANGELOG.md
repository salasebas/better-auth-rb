# Changelog

## Unreleased

- Kept the compatibility adapter aligned with MongoDB migration-control
  behavior and its generator coverage.

## [0.11.1](https://github.com/salasebas/better-auth-rb/compare/better_auth-mongo-adapter/v0.11.0...better_auth-mongo-adapter/v0.11.1) (2026-07-23)


### Miscellaneous Chores

* **better_auth-mongo-adapter:** Synchronize better-auth-release versions

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-mongo-adapter-v0.10.0...better_auth-mongo-adapter/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.

### Bug Fixes

* **ci:** restore package .ruby-version files for setup-ruby ([c18d220](https://github.com/salasebas/better-auth-rb/commit/c18d220065f3cb7cd2504bef7aa407e2c0c027eb))
* **rate-limit:** enforce atomic request limits ([3d7b145](https://github.com/salasebas/better-auth-rb/commit/3d7b145034880459ca7582061ebc4744e12f20a8))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

## 0.10.0 - 2026-05-21

- Deprecated this package in favor of `better_auth-mongodb`.
- Kept `require "better_auth/mongo_adapter"` as a compatibility entrypoint.
- Kept compatibility behavior aligned with the canonical MongoDB adapter.

## 0.7.0 - 2026-05-05

- Added explicit `ensure_indexes!` setup helper for Mongo indexes derived from Better Auth schema metadata.
- Updated MongoDB setup docs to use the lambda adapter form, clearer standalone/replica-set transaction guidance, and production index guidance.
- Consolidated Mongo fake test support and strengthened transaction rollback coverage for staged mutations.
- Apply `advanced[:database][:default_find_many_limit]` to uncapped `find_many` calls and one-to-many Mongo `$lookup` joins, defaulting to 100 when omitted.
- Match upstream Mongo where-clause semantics for mixed connectors by bucketing multi-clause filters into `$and` and `$or` arrays instead of left-fold nesting.
- Allow scalar values for `in` and `not_in` filters as an intentional Ruby adapter-family adaptation.

## 0.1.1 - 2026-04-30

- Fixed inferred limited joins so explicit relation and limit configuration is preserved.
- Added MongoDB upstream parity coverage using a fake Mongo adapter harness.

## 0.1.0

- Extract MongoDB adapter support into the `better_auth-mongo-adapter` package.
- Align MongoDB adapter behavior with upstream Better Auth v1.6.9, including where-clause key variants, falsey value handling, ID normalization, and external adapter compatibility coverage.
