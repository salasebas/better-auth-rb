# Changelog

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
