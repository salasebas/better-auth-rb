# Changelog

## Unreleased

- **Breaking:** SAML is no longer a transitive dependency. Add `gem "better_auth-saml"` when using SAML providers.
- Split protocol code into `better_auth-oidc` and `better_auth-saml`; this gem is now the convenience facade.
- Hardened provider/domain lifecycle and SAML/OIDC request validation, with
  regression coverage for the supported Ruby protocol paths.
- Added a checked upstream test inventory for the SSO plugin surface.

## [0.11.1](https://github.com/salasebas/better-auth-rb/compare/better_auth-sso/v0.11.0...better_auth-sso/v0.11.1) (2026-07-23)


### Miscellaneous Chores

* **better_auth-sso:** Synchronize better-auth-release versions

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-sso-v0.10.0...better_auth-sso/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.

### Features

* **schema:** align migration plugin schema parity ([c0261dc](https://github.com/salasebas/better-auth-rb/commit/c0261dc1e5fd649557cd8a57b92c0609620c3767))


### Bug Fixes

* **auth:** prevent unverified account takeover ([caae231](https://github.com/salasebas/better-auth-rb/commit/caae23154600a19f637c247466b55404839a2f7a))
* **ci:** restore package .ruby-version files for setup-ruby ([c18d220](https://github.com/salasebas/better-auth-rb/commit/c18d220065f3cb7cd2504bef7aa407e2c0c027eb))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))
* **saml:** fail closed without response parser ([#40](https://github.com/salasebas/better-auth-rb/issues/40)) ([87cc82c](https://github.com/salasebas/better-auth-rb/commit/87cc82c05db8868cba43e1a756b2d7777928c151))
* **saml:** verify signed SLO XML messages ([#43](https://github.com/salasebas/better-auth-rb/issues/43)) ([e7730cf](https://github.com/salasebas/better-auth-rb/commit/e7730cf01a683a4b24f1506fd52fda624f4ef028))
* **sso:** harden OIDC endpoint fetching ([#38](https://github.com/salasebas/better-auth-rb/issues/38)) ([177bf8b](https://github.com/salasebas/better-auth-rb/commit/177bf8b847ba4e2a8478d82338b3e4cc7b91932d))
* **sso:** harden provider and SAML lifecycle ([bb81ef0](https://github.com/salasebas/better-auth-rb/commit/bb81ef003359275f3de5080ac708ef12a02f3c56))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

## 0.10.0 - 2026-05-21

- Hardened SSO redirect, OIDC, SAML metadata, logout, and response handling.
- Expanded adapter, Rack edge-case, and rate-limit coverage.

## 0.7.0 - 2026-05-05

- Fixed SAML config validation for `singleSignOnService` and added validation for `singleLogoutService`.
- Hardened OIDC callbacks by binding signed state `providerId` to the callback route and verifying `nonce` on JWKS-backed ID tokens.
- Changed SSO domain verification to require exact TXT record matches and corrected the insufficient access error code to `INSUFFICIENT_ACCESS`.
- Declared `jwt` as a direct runtime dependency for the SSO gem.
- Added regression coverage for SAML SP metadata XML responses.

## 0.2.0 - 2026-04-29

- Improved SSO upstream parity for OIDC and SAML provider flows, organization handling, callback behavior, metadata parsing, account linking, and response/error shapes.
- Expanded SSO documentation and coverage for SAML, OIDC, and ruby-saml integration paths.

## 0.1.0

- Initial package skeleton for Better Auth SSO.
