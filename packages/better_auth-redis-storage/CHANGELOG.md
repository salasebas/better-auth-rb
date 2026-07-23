# Changelog

## Unreleased

- Added a checked upstream test inventory for the Redis storage reference
  surface, including explicit Ruby-specific classifications.

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-redis-storage-v0.10.0...better_auth-redis-storage/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.

### Features

* **adapters:** add atomic storage primitives ([8d715c9](https://github.com/salasebas/better-auth-rb/commit/8d715c92ba2dbd4aa4b167a3319a9ac94c629519))


### Bug Fixes

* **api-key:** make verification counters authoritative ([6550ae7](https://github.com/salasebas/better-auth-rb/commit/6550ae753f104f771e313360f56e6fdcff82d005))
* **ci:** restore package .ruby-version files for setup-ruby ([c18d220](https://github.com/salasebas/better-auth-rb/commit/c18d220065f3cb7cd2504bef7aa407e2c0c027eb))
* **rate-limit:** enforce atomic request limits ([3d7b145](https://github.com/salasebas/better-auth-rb/commit/3d7b145034880459ca7582061ebc4744e12f20a8))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

## 0.10.0 - 2026-05-21

- Released in sync with the full Better Auth package set.

## 0.7.0 - 2026-05-05

- Validate `scan_count` as either `nil` or a positive `Integer`.
- Reject `nil` logical keys before prefixing Redis keys.
- Coerce positive finite non-Integer `Numeric` TTL values for `SETEX`.
- Fall back to plain `SET` for positive sub-second numeric TTLs that would truncate to `0`.
- Delete `clear` matches in chunks to avoid oversized Redis `DEL` commands.
- Stream `clear` deletion by `SCAN` page when `scan_count:` is configured.
- Add `atomic_clear:` opt-in generation-scoped keys so `clear` is logically atomic under concurrent writers.
- Run the real Redis integration suite explicitly in CI and release verification.
- Document Redis operational caveats for empty prefixes, key ordering, TTLs, and clusters.

## 0.2.0 - 2026-04-29

- Add `BetterAuth.redis_storage` and `BetterAuth::RedisStorage.redisStorage` builders for upstream-shaped Redis storage configuration.
- Add optional `scan_count:` support to use Redis `SCAN` instead of upstream-compatible `KEYS`.
- Split real Redis coverage into a `REDIS_INTEGRATION=1` integration suite and expand secondary-storage compatibility tests.

## 0.1.0

- Initial Redis secondary storage package for Better Auth Ruby.
