# Changelog

## Unreleased

- Added a checked upstream test inventory for the Redis storage reference
  surface, including explicit Ruby-specific classifications.

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
