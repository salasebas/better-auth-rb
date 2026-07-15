# Changelog

## Unreleased

- Hardened API-key verification and counter updates where authoritative adapter
  operations are available, with regression coverage for stale-write cases.
- Added a checked upstream test inventory for this plugin's pinned reference
  files.

## 0.10.0 - 2026-05-21

- Improved adapter coverage and Redis-backed storage behavior for API key flows.
- Tightened API key listing behavior so responses stay consistent across supported adapters.

## 0.7.0 - 2026-05-05

- Changed API-key-backed sessions to expose `tokenFingerprint` instead of storing the raw API key in `session["token"]`.
- Hardened API key listing and expired-key cleanup behavior.
- Improved API key metadata handling and added regression coverage for session fingerprint behavior.

## 0.2.1 - 2026-04-30

- Fixed API key metadata normalization so symbol and string metadata keys preserve nested metadata payloads.
- Added upstream parity coverage for API key behavior and error-code response details.

## 0.2.0 - 2026-04-29

- Aligned API key behavior with upstream Better Auth v1.6.9, including key verification, permission checks, metadata updates, expiration, rate limiting, prefix handling, and route response shapes.
- Expanded package documentation and executable coverage for upstream API key edge cases.

## 0.1.0

- Extract API key support into the `better_auth-api-key` package.
