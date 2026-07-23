# Changelog

## Unreleased

- Honored plugin migration controls in MongoDB schema/index generation and
  added regression coverage for the supported generator path.

## [0.11.1](https://github.com/salasebas/better-auth-rb/compare/better_auth-mongodb/v0.11.0...better_auth-mongodb/v0.11.1) (2026-07-23)


### Miscellaneous Chores

* **better_auth-mongodb:** Synchronize better-auth-release versions

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-mongodb-v0.10.0...better_auth-mongodb/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.

### Features

* **adapters:** add atomic storage primitives ([8d715c9](https://github.com/salasebas/better-auth-rb/commit/8d715c92ba2dbd4aa4b167a3319a9ac94c629519))
* **schema:** align migration plugin schema parity ([c0261dc](https://github.com/salasebas/better-auth-rb/commit/c0261dc1e5fd649557cd8a57b92c0609620c3767))
* **schema:** honor plugin migration controls ([#48](https://github.com/salasebas/better-auth-rb/issues/48)) ([c67e8bf](https://github.com/salasebas/better-auth-rb/commit/c67e8bf216a2b5f8ad52f53cb9f56e6cfbfa39bb))


### Bug Fixes

* **adapters:** fail closed on singular updates ([c7cf07f](https://github.com/salasebas/better-auth-rb/commit/c7cf07fe19887d682eb94956617532d840beb018))
* **ci:** restore package .ruby-version files for setup-ruby ([c18d220](https://github.com/salasebas/better-auth-rb/commit/c18d220065f3cb7cd2504bef7aa407e2c0c027eb))
* **rate-limit:** enforce atomic request limits ([3d7b145](https://github.com/salasebas/better-auth-rb/commit/3d7b145034880459ca7582061ebc4744e12f20a8))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))
* **two-factor:** enforce verification attempt limits ([f0a8bf4](https://github.com/salasebas/better-auth-rb/commit/f0a8bf4789e9105191e951452879ab09589f5592))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

## 0.10.0 - 2026-05-21

- Rename the canonical Ruby gem to `better_auth-mongodb` while keeping
  `better_auth-mongo-adapter` as a deprecated compatibility package.
- Fixed `use_plural: true` so configured schema `model_name` values such as
  `people` and `api_keys` are used directly instead of being pluralized again.
- Clarified MongoDB filter docs: `in` requires array values, while `not_in`
  accepts scalar values as a Ruby adapter-family compatibility behavior.
- Improved MongoDB owner counting, nullable unique indexes, and adapter parity coverage.

## 0.7.0 - 2026-05-05

- Added explicit `ensure_indexes!` setup helper for Mongo indexes derived from Better Auth schema metadata.
- Updated MongoDB setup docs to use the lambda adapter form, clearer standalone/replica-set transaction guidance, and production index guidance.
- Consolidated Mongo fake test support and strengthened transaction rollback coverage for staged mutations.
- Apply `advanced[:database][:default_find_many_limit]` to uncapped `find_many` calls and one-to-many Mongo `$lookup` joins, defaulting to 100 when omitted.
- Match upstream Mongo where-clause semantics for mixed connectors by bucketing multi-clause filters into `$and` and `$or` arrays instead of left-fold nesting.
- Allow scalar values for `not_in` filters as an intentional Ruby adapter-family adaptation while keeping `in` aligned with the shared adapter array contract.

## 0.1.1 - 2026-04-30

- Fixed inferred limited joins so explicit relation and limit configuration is preserved.
- Added MongoDB upstream parity coverage using a fake Mongo adapter harness.

## 0.1.0

- Extract MongoDB adapter support into the `better_auth-mongo-adapter` package.
- Align MongoDB adapter behavior with upstream Better Auth v1.6.9, including where-clause key variants, falsey value handling, ID normalization, and external adapter compatibility coverage.
