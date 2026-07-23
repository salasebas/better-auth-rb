# Changelog

## [0.11.1](https://github.com/salasebas/better-auth-rb/compare/better_auth-passkey/v0.11.0...better_auth-passkey/v0.11.1) (2026-07-23)


### Miscellaneous Chores

* **better_auth-passkey:** Synchronize better-auth-release versions

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-passkey-v0.10.0...better_auth-passkey/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.

### Features

* **auth:** complete API catalog parity ([234fd77](https://github.com/salasebas/better-auth-rb/commit/234fd77983866dbdcb6be8a3d1b2604a7fd0ce60))
* **passkey:** use post for challenge generation ([9eb67b1](https://github.com/salasebas/better-auth-rb/commit/9eb67b19537317dc90b2e2ba7341468d240c4193))
* **schema:** align migration plugin schema parity ([c0261dc](https://github.com/salasebas/better-auth-rb/commit/c0261dc1e5fd649557cd8a57b92c0609620c3767))


### Bug Fixes

* **auth:** consume single-use state atomically ([07bedc1](https://github.com/salasebas/better-auth-rb/commit/07bedc1c114189e0039a63f2a0cf377658fe457c))
* **ci:** restore package .ruby-version files for setup-ruby ([c18d220](https://github.com/salasebas/better-auth-rb/commit/c18d220065f3cb7cd2504bef7aa407e2c0c027eb))
* load external plugin gems without stub recursion ([4926bae](https://github.com/salasebas/better-auth-rb/commit/4926bae7520c17438de25e99cb2155839c177493))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

## [Unreleased]

- Improved server-side authenticator metadata and management-route parity with
  targeted regression coverage.
- Added a checked upstream test inventory for Passkey server behavior.

## [0.10.0] - 2026-05-21

- Improved passkey challenge handling, management routes, rate limits, and adapter coverage.

## [0.7.0] - 2026-05-05

- Require a fresh session for session-required passkey registration verification.
- Return `BAD_REQUEST` for passkey registration WebAuthn verification failures while preserving `INTERNAL_SERVER_ERROR` for unexpected failures.
- Invalidate stored WebAuthn challenges after failed registration or authentication verification attempts.
- Read passkey attestation metadata via the public `credential.response` API from the `webauthn` gem.
- Invalidate authentication challenges after all terminal failures once a valid challenge is loaded, including missing credentials, callback errors, and session creation failures.
- Reject duplicate registered WebAuthn credential IDs with `PREVIOUSLY_REGISTERED` and mark `credentialID` unique in the passkey schema.

## [0.2.0] - 2026-04-29

- Aligned passkey registration, authentication, verification, origin handling, credential metadata, and route behavior with upstream Better Auth v1.6.9.
- Expanded passkey documentation and test coverage for upstream server parity.

## [0.1.0] - 2026-04-28

- Initial external passkey package extracted from `better_auth`.
