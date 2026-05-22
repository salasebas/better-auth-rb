# Changelog

## Unreleased

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
