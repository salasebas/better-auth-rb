# Changelog

## Unreleased

- Hardened SCIM provisioning, identity linking, deprovisioning, and PATCH/PUT
  handling with regression coverage for supported adapters.
- Added a checked upstream test inventory for the SCIM plugin surface.

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-scim-v0.10.0...better_auth-scim/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.

### Features

* **schema:** align migration plugin schema parity ([c0261dc](https://github.com/salasebas/better-auth-rb/commit/c0261dc1e5fd649557cd8a57b92c0609620c3767))


### Bug Fixes

* **ci:** restore package .ruby-version files for setup-ruby ([c18d220](https://github.com/salasebas/better-auth-rb/commit/c18d220065f3cb7cd2504bef7aa407e2c0c027eb))
* load external plugin gems without stub recursion ([4926bae](https://github.com/salasebas/better-auth-rb/commit/4926bae7520c17438de25e99cb2155839c177493))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))
* **scim:** harden provisioning lifecycle ([da956cd](https://github.com/salasebas/better-auth-rb/commit/da956cd117f991f3632ce22611e32b97b1bd1e24))
* **session:** enforce authoritative session checks ([0eebb9b](https://github.com/salasebas/better-auth-rb/commit/0eebb9b1a10f9cceaaa05401084fb0d07065c1e3))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

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
