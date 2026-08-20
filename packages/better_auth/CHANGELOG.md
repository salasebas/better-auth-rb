# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.11.1](https://github.com/salasebas/better-auth-rb/compare/better_auth/v0.11.0...better_auth/v0.11.1) (2026-08-20)


### Bug Fixes

* **admin:** enforce exact role case authorization ([#72](https://github.com/salasebas/better-auth-rb/issues/72)) ([ca19ff8](https://github.com/salasebas/better-auth-rb/commit/ca19ff8d7af0e8f173923277f3291e7928df2999))
* **admin:** handle list-users adapter failures ([#93](https://github.com/salasebas/better-auth-rb/issues/93)) ([43705ac](https://github.com/salasebas/better-auth-rb/commit/43705ac7eb716f9d8588bf872b6b8ad4c5376e21))
* **admin:** require canonical get-user id ([#103](https://github.com/salasebas/better-auth-rb/issues/103)) ([712d331](https://github.com/salasebas/better-auth-rb/commit/712d331716bfc0bebf032d32fe96347f29ca82a5))
* **anonymous:** link users after email verification ([#77](https://github.com/salasebas/better-auth-rb/issues/77)) ([da1d7d0](https://github.com/salasebas/better-auth-rb/commit/da1d7d0ad092f6220f6f58654261abd2a3c20237))
* **auth:** align delete-user token expiry ([#90](https://github.com/salasebas/better-auth-rb/issues/90)) ([028e9d0](https://github.com/salasebas/better-auth-rb/commit/028e9d06a0219ffd1b8b62e9d39757bdd1d960ef))
* **auth:** allow optional social provider client secrets ([#67](https://github.com/salasebas/better-auth-rb/issues/67)) ([e72021f](https://github.com/salasebas/better-auth-rb/commit/e72021f037ef26a2df96b904f310374fbe16fcb2))
* **auth:** canonicalize email verification errors ([#94](https://github.com/salasebas/better-auth-rb/issues/94)) ([3630dad](https://github.com/salasebas/better-auth-rb/commit/3630dadeb7d370cee6477b744f5a2e0a6ee11f16))
* **auth:** default OAuth state to verification storage ([#79](https://github.com/salasebas/better-auth-rb/issues/79)) ([6a2b24c](https://github.com/salasebas/better-auth-rb/commit/6a2b24c2d3fd9b28d37abbab20d1f3588c3c9ccf))
* **auth:** reject incomplete change-email confirmation flow ([#84](https://github.com/salasebas/better-auth-rb/issues/84)) ([e21d7e6](https://github.com/salasebas/better-auth-rb/commit/e21d7e61bf024bd58cc4b34b25312ac812acfadf))
* **auth:** reject revoked sessions on provider token routes ([#76](https://github.com/salasebas/better-auth-rb/issues/76)) ([af375b1](https://github.com/salasebas/better-auth-rb/commit/af375b123dc1d8d2d02fab49810774e978eee1a3))
* **auth:** require authoritative delete verification ([#100](https://github.com/salasebas/better-auth-rb/issues/100)) ([36feb61](https://github.com/salasebas/better-auth-rb/commit/36feb61e7864ff9716aecb0f79b6c63a42f52204))
* **auth:** sync Generic OAuth profile on explicit link ([#101](https://github.com/salasebas/better-auth-rb/issues/101)) ([cae2b45](https://github.com/salasebas/better-auth-rb/commit/cae2b4503b58b72bb7c3a5f51d1dd86907a3cd9b))
* **core:** align HIBP protected paths ([#65](https://github.com/salasebas/better-auth-rb/issues/65)) ([6e8c24c](https://github.com/salasebas/better-auth-rb/commit/6e8c24cf67f147561860aedc9a836237d6b283a8))
* **core:** align literal-enum SQL parity ([49ca890](https://github.com/salasebas/better-auth-rb/commit/49ca890a78f2fc44b34ea03e70b1fa62d8a87905))
* **core:** align organization invitation creation ([#82](https://github.com/salasebas/better-auth-rb/issues/82)) ([165eac5](https://github.com/salasebas/better-auth-rb/commit/165eac54f38b1152cd4ffaee1a1f6affa1a67b42))
* **core:** align session-only refresh behavior ([2dac697](https://github.com/salasebas/better-auth-rb/commit/2dac69712db0785e2a3526f50ff50110455e6e24))
* **core:** allow phone number disassociation ([#75](https://github.com/salasebas/better-auth-rb/issues/75)) ([da9e102](https://github.com/salasebas/better-auth-rb/commit/da9e102b8fe2bdb865a461970f02ad5ff803e43b))
* **core:** await phone verification callback ([#96](https://github.com/salasebas/better-auth-rb/issues/96)) ([ee5bc48](https://github.com/salasebas/better-auth-rb/commit/ee5bc4866e3f05d68059197c113c1a96df105cf8))
* **core:** bind multi-session actions to verified token ([#69](https://github.com/salasebas/better-auth-rb/issues/69)) ([8070d35](https://github.com/salasebas/better-auth-rb/commit/8070d35a83f5e7de92b9b02f02c8203f2d1049ef))
* **core:** canonicalize request IP normalization ([8d7f345](https://github.com/salasebas/better-auth-rb/commit/8d7f3456cda19ec14ed28322adefd9d8831d85f0))
* **core:** classify special-use IPv6 hosts ([#62](https://github.com/salasebas/better-auth-rb/issues/62)) ([2951648](https://github.com/salasebas/better-auth-rb/commit/295164826c9b61d90fadb835c4034cb3f2ec3416))
* **core:** default omitted schema fields to required ([#89](https://github.com/salasebas/better-auth-rb/issues/89)) ([f570148](https://github.com/salasebas/better-auth-rb/commit/f570148f20b6910a34d122b58884143e2f6155e8))
* **core:** enforce path segment matcher boundaries ([#98](https://github.com/salasebas/better-auth-rb/issues/98)) ([ba26891](https://github.com/salasebas/better-auth-rb/commit/ba268919a58bd7d8abe67f2ad187b04baf77db42))
* **core:** honor default find_many limits ([#102](https://github.com/salasebas/better-auth-rb/issues/102)) ([d23ee5a](https://github.com/salasebas/better-auth-rb/commit/d23ee5aeac2cf904c204c0b12634693e8d8169c7))
* **core:** make sign-out resilient to delete failures ([#66](https://github.com/salasebas/better-auth-rb/issues/66)) ([8667d9d](https://github.com/salasebas/better-auth-rb/commit/8667d9d11980e9c33a2ae9182739d5379b2ad907))
* **core:** preserve exact rate-limit expiry boundaries ([#85](https://github.com/salasebas/better-auth-rb/issues/85)) ([c465f5c](https://github.com/salasebas/better-auth-rb/commit/c465f5c474e7a3b29486a3a8b504d2491b6bace6))
* **core:** preserve MySQL connection URL options ([#83](https://github.com/salasebas/better-auth-rb/issues/83)) ([06f657d](https://github.com/salasebas/better-auth-rb/commit/06f657d9b4310f9e83cbfad12bb1e60714291345))
* **core:** preserve session-only cookie lifetime ([7e11eba](https://github.com/salasebas/better-auth-rb/commit/7e11eba6df5651827f4e89041229cf64d6b44a1e))
* **core:** preserve session-only cookie lifetime ([fa0ebbd](https://github.com/salasebas/better-auth-rb/commit/fa0ebbd70d5c0226f89b6aaec787f521c6d03d15))
* **core:** refresh cookie cache by remaining ttl ([#91](https://github.com/salasebas/better-auth-rb/issues/91)) ([4b5edb6](https://github.com/salasebas/better-auth-rb/commit/4b5edb6e7d954eac2c0253991192ef8ff6210000))
* **core:** reject non-string callback redirects ([#73](https://github.com/salasebas/better-auth-rb/issues/73)) ([1f176e1](https://github.com/salasebas/better-auth-rb/commit/1f176e1ad5a7ef50051dc2bde3f7a4360099e672))
* **core:** route server-scoped endpoints over HTTP ([#63](https://github.com/salasebas/better-auth-rb/issues/63)) ([f0fc50c](https://github.com/salasebas/better-auth-rb/commit/f0fc50c03a7b3d2813daf1bb669ee73e8a9592f8))
* **core:** scope form csrf to email auth routes ([#88](https://github.com/salasebas/better-auth-rb/issues/88)) ([8bb2137](https://github.com/salasebas/better-auth-rb/commit/8bb213772aecabc290d24c2b9561ccc7c60c8216))
* **core:** support literal-enum SQL field types ([542c534](https://github.com/salasebas/better-auth-rb/commit/542c534e60892e908c8bbc2037f1adcf0f4d5ebe))
* **core:** support literal-enum SQL field types ([5aaea0d](https://github.com/salasebas/better-auth-rb/commit/5aaea0d97a3a193403a9afe3d4733ab88ce50987))
* **expo:** validate authorization proxy targets ([#64](https://github.com/salasebas/better-auth-rb/issues/64)) ([bde0448](https://github.com/salasebas/better-auth-rb/commit/bde04483aec9d16f7426219923980a9fd71d4845))
* generate RFC-compliant social PKCE verifiers ([#86](https://github.com/salasebas/better-auth-rb/issues/86)) ([1f78bc9](https://github.com/salasebas/better-auth-rb/commit/1f78bc9c5ea2d2e44637f6c9a90528583a4da86d))
* **generic-oauth:** resolve account id fallbacks ([#78](https://github.com/salasebas/better-auth-rb/issues/78)) ([725f23d](https://github.com/salasebas/better-auth-rb/commit/725f23d63a59c1ce6c0120fafee71d9765bb83ad))
* **last-login-method:** persist tracking through database hooks ([#74](https://github.com/salasebas/better-auth-rb/issues/74)) ([663600d](https://github.com/salasebas/better-auth-rb/commit/663600dc3a05856bf0e1697bb04f9f0a9d264476))
* **memory:** fail closed on empty singular delete ([#80](https://github.com/salasebas/better-auth-rb/issues/80)) ([1b62bde](https://github.com/salasebas/better-auth-rb/commit/1b62bdede115461cb3ce46117c7d0489cb591f02))
* **oauth-provider:** align default scopes ([6b075a4](https://github.com/salasebas/better-auth-rb/commit/6b075a46298a17b86c046a1a059b94e25f4e1d66))
* **oauth-provider:** complete default scope parity ([5afcf2c](https://github.com/salasebas/better-auth-rb/commit/5afcf2cff2deb2adda2a960f32422a6cd031904f))
* **oauth-provider:** encrypt JWT-disabled client secrets ([#104](https://github.com/salasebas/better-auth-rb/issues/104)) ([aa04489](https://github.com/salasebas/better-auth-rb/commit/aa04489aa71161b09be2d615d2361161f3371b9b))

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
