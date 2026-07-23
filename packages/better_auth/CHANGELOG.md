# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-v0.10.0...better_auth/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.
* **oauth-provider:** unify OAuth/OIDC/MCP under oauth_provider gem

### Features

* **adapters:** add atomic storage primitives ([8d715c9](https://github.com/salasebas/better-auth-rb/commit/8d715c92ba2dbd4aa4b167a3319a9ac94c629519))
* **auth:** complete API catalog parity ([234fd77](https://github.com/salasebas/better-auth-rb/commit/234fd77983866dbdcb6be8a3d1b2604a7fd0ce60))
* **auth:** improve OAuth provider parity ([3c1c3c3](https://github.com/salasebas/better-auth-rb/commit/3c1c3c3466dd4782732c988555fe80bc43a1abbd))
* **better_auth:** lazy-load in-core plugins on demand ([66c3002](https://github.com/salasebas/better-auth-rb/commit/66c300212e6f72bf41284b73ac7207a9b2886af9))
* **cli:** add config discovery, secret, and info diagnostics ([e522cf6](https://github.com/salasebas/better-auth-rb/commit/e522cf6755512b465dbf2f2589eb2335db6f1af4))
* **core:** add i18n plugin ([ab6a2f3](https://github.com/salasebas/better-auth-rb/commit/ab6a2f38750c3be141dba21c039c84ec603b2a68))
* **email-otp:** remove deprecated password reset alias ([bc4614a](https://github.com/salasebas/better-auth-rb/commit/bc4614a23bbd7464e56455777b6b980f20d7e012))
* **oauth-provider:** align protocol behavior with upstream ([9217273](https://github.com/salasebas/better-auth-rb/commit/9217273069ffa2c18d256a8c1d9d5487a8d316c1))
* **oauth-provider:** unify OAuth/OIDC/MCP under oauth_provider gem ([7d16def](https://github.com/salasebas/better-auth-rb/commit/7d16def22ea26f753e520e95522568261eca2090))
* **organization:** align membership limits and lifecycle hooks ([81ab81e](https://github.com/salasebas/better-auth-rb/commit/81ab81ef80aa6d35a6f4bf8a4e54be910fd07aa6))
* **schema:** align migration plugin schema parity ([c0261dc](https://github.com/salasebas/better-auth-rb/commit/c0261dc1e5fd649557cd8a57b92c0609620c3767))
* **schema:** honor plugin migration controls ([#48](https://github.com/salasebas/better-auth-rb/issues/48)) ([c67e8bf](https://github.com/salasebas/better-auth-rb/commit/c67e8bf216a2b5f8ad52f53cb9f56e6cfbfa39bb))


### Bug Fixes

* **adapters:** fail closed on singular updates ([c7cf07f](https://github.com/salasebas/better-auth-rb/commit/c7cf07fe19887d682eb94956617532d840beb018))
* **adapters:** preserve joined records with projected queries ([#47](https://github.com/salasebas/better-auth-rb/issues/47)) ([acd9197](https://github.com/salasebas/better-auth-rb/commit/acd919746715c15a752f0b2861322d09a4f49f20))
* **auth:** consume single-use state atomically ([07bedc1](https://github.com/salasebas/better-auth-rb/commit/07bedc1c114189e0039a63f2a0cf377658fe457c))
* **auth:** harden email change verification ([#45](https://github.com/salasebas/better-auth-rb/issues/45)) ([56f631a](https://github.com/salasebas/better-auth-rb/commit/56f631ac9ead26bf7f5719b07ade5ebbac7f3a0a))
* **auth:** harden token link base URLs ([#36](https://github.com/salasebas/better-auth-rb/issues/36)) ([22d714c](https://github.com/salasebas/better-auth-rb/commit/22d714ce6183b51b555424ebb7e3d2ca0dd36967))
* **auth:** prevent unverified account takeover ([caae231](https://github.com/salasebas/better-auth-rb/commit/caae23154600a19f637c247466b55404839a2f7a))
* **auth:** use secure magic-link tokens ([#46](https://github.com/salasebas/better-auth-rb/issues/46)) ([20fcc0b](https://github.com/salasebas/better-auth-rb/commit/20fcc0bbe44371332c2f11187b34d70b3c57e2ce))
* **auth:** validate social provider identities ([2028af8](https://github.com/salasebas/better-auth-rb/commit/2028af879e4ac61ebc30b3cbc0a4aa32b2d497fe))
* **ci:** resolve Ruby 3.4 lint, plugin loading, and upstream parity ([ecf5edd](https://github.com/salasebas/better-auth-rb/commit/ecf5edd032eb3695e94456754779656fe017cd7b))
* **core:** clear session cookies when signed session token is invalid ([d7c2702](https://github.com/salasebas/better-auth-rb/commit/d7c2702529bb6aa0e6fbdc54d1ca5f610c46effb))
* **core:** harden plugin security and parity ([1cb70f9](https://github.com/salasebas/better-auth-rb/commit/1cb70f940aca6186b39cd2e3f438fe197fbb5495))
* **core:** prefer adapter execute over Kernel#exec in SQL migrations ([fe99b4f](https://github.com/salasebas/better-auth-rb/commit/fe99b4f4bf6bb20e138691b9e777d64620f8cde4))
* **core:** restore access-control factory and MSSQL execute signature ([040f583](https://github.com/salasebas/better-auth-rb/commit/040f5839ebe788448cbc39dd403b9ba6a19e50eb))
* **email-otp:** keep OTP helpers server-only ([#42](https://github.com/salasebas/better-auth-rb/issues/42)) ([99d2469](https://github.com/salasebas/better-auth-rb/commit/99d2469029d6e5b0f439c1b5ed868c544da443f2))
* harden client IP rate-limit keys ([#39](https://github.com/salasebas/better-auth-rb/issues/39)) ([cb2fefd](https://github.com/salasebas/better-auth-rb/commit/cb2fefd543ef92f8c2c10fedef7f3bd659a90196))
* load external plugin gems without stub recursion ([4926bae](https://github.com/salasebas/better-auth-rb/commit/4926bae7520c17438de25e99cb2155839c177493))
* **organization:** enforce membership limit on member creation ([8f7796a](https://github.com/salasebas/better-auth-rb/commit/8f7796aa093c98239914492e66b62e4f1364896b))
* **organization:** protect creator role updates ([#44](https://github.com/salasebas/better-auth-rb/issues/44)) ([acf03a4](https://github.com/salasebas/better-auth-rb/commit/acf03a4a97d6f4e2a8e4aea88e1fb79cb5197fca))
* **plugins:** enforce organization and device ownership ([1177216](https://github.com/salasebas/better-auth-rb/commit/117721660a4323926456c5c8b0461c77ff5e651f))
* **rate-limit:** enforce atomic request limits ([3d7b145](https://github.com/salasebas/better-auth-rb/commit/3d7b145034880459ca7582061ebc4744e12f20a8))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))
* **saml:** verify signed SLO XML messages ([#43](https://github.com/salasebas/better-auth-rb/issues/43)) ([e7730cf](https://github.com/salasebas/better-auth-rb/commit/e7730cf01a683a4b24f1506fd52fda624f4ef028))
* **scim:** harden provisioning lifecycle ([da956cd](https://github.com/salasebas/better-auth-rb/commit/da956cd117f991f3632ce22611e32b97b1bd1e24))
* separate canonical and serving origins ([#37](https://github.com/salasebas/better-auth-rb/issues/37)) ([c1bd12e](https://github.com/salasebas/better-auth-rb/commit/c1bd12e81a1cb21a8d0ba186cefd554753e565f6))
* **session:** enforce authoritative session checks ([0eebb9b](https://github.com/salasebas/better-auth-rb/commit/0eebb9b1a10f9cceaaa05401084fb0d07065c1e3))
* **siwe:** add get-nonce compatibility alias ([#49](https://github.com/salasebas/better-auth-rb/issues/49)) ([543478d](https://github.com/salasebas/better-auth-rb/commit/543478d2423b4411c68c2069d633ef268a1010a5))
* **sso:** harden OIDC endpoint fetching ([#38](https://github.com/salasebas/better-auth-rb/issues/38)) ([177bf8b](https://github.com/salasebas/better-auth-rb/commit/177bf8b847ba4e2a8478d82338b3e4cc7b91932d))
* **two-factor:** enforce verification attempt limits ([f0a8bf4](https://github.com/salasebas/better-auth-rb/commit/f0a8bf4789e9105191e951452879ab09589f5592))
* unblock SAML/OIDC CI and release workflows ([9d7ed4e](https://github.com/salasebas/better-auth-rb/commit/9d7ed4eb9097a8bf05863bf90f9ba00ae5f2ec76))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

## [Unreleased]

### Added

- Added the experimental `oauth_popup` server plugin with built-in and Generic
  OAuth state validation, strict opener-origin checks, callback cookie
  preservation, and optional Bearer integration.

### Fixed

- Hardened existing-identity linking, authoritative session checks, single-use
  state consumption, and rate-limit behavior with regression coverage.
- Made verification state atomic where the configured adapter supports the
  required primitives, while retaining documented adapter compatibility paths.
- Aligned OAuth Popup state confidentiality and single-use callback behavior,
  duplicate session-cookie handling, and hidden endpoint metadata with upstream
  v1.6.23.

### Changed

- Added a checked upstream server-test inventory for the pinned v1.6.23
  reference; it distinguishes covered, adapted, not-applicable, and planned
  behavior rather than asserting blanket version parity.

## [0.10.0] - 2026-05-21

### Fixed

- Fixed organization owner counting to page through adapter results instead of
  relying on a single uncapped `find_many` call.
- Improved SQL, memory, cookie, rate-limit, plugin schema, social login, and
  auth response edge cases for more consistent behavior across adapters.

## [0.7.0] - 2026-05-05

### Added

- Completed OpenAPI support with upstream v1.6.9 base-route schema parity, `/ok` and `/error` documentation, richer helper-generated schemas, plugin endpoint metadata coverage, and Scalar reference configuration parity.
- Added shared join query handling for adapter-backed relation loading.

### Changed

- Modernized the MCP plugin to use OAuth Provider-style client, token, metadata, and protected-resource behavior while keeping legacy MCP routes as aliases.
- Changed OAuth HS256 ID token signing to use non-public key material; existing ID tokens signed only with the public client id will no longer validate.

### Fixed

- Fixed OAuth refresh token rotation to reject refresh tokens presented by a different authenticated client.
- Fixed OAuth client-secret verification to use constant-time comparison for encrypted and custom-hashed storage modes.
- Hardened router and OAuth protocol behavior around path handling, issuer metadata, and public route coverage.

## [0.4.0] - 2026-04-30

### Added

- Added upstream-parity helpers for async execution, host resolution, instrumentation, request state, URL handling, OAuth2, deprecation warnings, and expanded route behavior.
- Added two-factor, OAuth protocol, social route, organization, admin, adapter, schema, and session parity coverage.

### Changed

- Aligned core auth, email OTP, generic OAuth, organization, two-factor, OAuth protocol, adapter, router, rate-limiter, logger, and middleware behavior more closely with upstream Better Auth.

### Fixed

- Fixed upstream parity gaps in organization handling, generic OAuth user info, email OTP sign-up, database schema behavior, and route/session edge cases.

## [0.3.0] - 2026-04-29

### Added

- Added upstream-parity social provider support, including provider-specific authorization, token, profile, refresh, and revocation behavior for the expanded provider set.
- Added OAuth/OIDC protocol hardening for authorization, callback, discovery, metadata, token, and userinfo flows.
- Added upstream v1.6.9 parity coverage for schema generation, adapter behavior, plugin hooks, session handling, and account/user route edge cases.

### Changed

- Extracted MongoDB adapter support behind the external `better_auth-mongodb` package while preserving compatibility for existing adapter configuration.
- Updated auth routes, router behavior, rate limiting, password and email-verification flows, and schema metadata to match upstream semantics more closely.

### Fixed

- Fixed social provider edge cases, magic-link expiration behavior, adapter value coercion, and callback/session handling across Rack integrations.

## [0.1.1] - 2026-03-22

### Fixed

- Fixed gemspec files list to use `Dir.glob` instead of `git ls-files` for better CI compatibility

### Added

- Initial project setup
- Basic gem structure
- StandardRB configuration
- Minitest for core testing
- RSpec for Rails adapter testing
- CI/CD workflows for GitHub Actions
