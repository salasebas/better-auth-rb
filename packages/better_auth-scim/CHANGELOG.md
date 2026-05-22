# Changelog

## Unreleased

## 0.10.0 - 2026-05-21

- Improved SCIM route, adapter, user, and rate-limit coverage.
- Clarified SCIM setup docs and runtime dependencies.

## 0.7.0 - 2026-05-05

- Changed generated SCIM provider tokens to use hashed storage by default. Set `store_scim_token: "plain"` only when plaintext database storage is intentionally required.
- Split provider management and validation flows and hardened SCIM user listing, patch handling, and auth error responses.

## 0.2.0 - 2026-04-29

- Aligned SCIM user and group provisioning behavior with upstream Better Auth v1.6.9, including filtering, patch operations, schema responses, error shapes, and token handling.
- Expanded SCIM documentation and tests for upstream parity flows.

## 0.1.0

- Initial package skeleton for Better Auth SCIM.
