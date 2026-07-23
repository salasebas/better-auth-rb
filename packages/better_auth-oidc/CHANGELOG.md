# Changelog

## Unreleased

- Split OIDC relying-party code out of `better_auth-sso` into a dedicated gem without `ruby-saml`.
- Documented and tested the Ruby OIDC integration boundary for the hardened SSO
  lifecycle work.

## [0.11.1](https://github.com/salasebas/better-auth-rb/compare/better_auth-oidc/v0.11.0...better_auth-oidc/v0.11.1) (2026-07-23)


### Miscellaneous Chores

* **better_auth-oidc:** Synchronize better-auth-release versions

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-oidc-v0.10.0...better_auth-oidc/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.

### Features

* **sso:** add better_auth-oidc and better_auth-saml protocol gems ([e6e12fc](https://github.com/salasebas/better-auth-rb/commit/e6e12fc5866e6f519325b766799a4ee3b8ea6358))


### Bug Fixes

* add Ruby version files for SAML and OIDC packages ([f2a7d03](https://github.com/salasebas/better-auth-rb/commit/f2a7d035397aad42ad6e1f4b65a5bd18fadf1ba4))
* **auth:** consume single-use state atomically ([07bedc1](https://github.com/salasebas/better-auth-rb/commit/07bedc1c114189e0039a63f2a0cf377658fe457c))
* **auth:** prevent unverified account takeover ([caae231](https://github.com/salasebas/better-auth-rb/commit/caae23154600a19f637c247466b55404839a2f7a))
* **ci:** restore package .ruby-version files for setup-ruby ([c18d220](https://github.com/salasebas/better-auth-rb/commit/c18d220065f3cb7cd2504bef7aa407e2c0c027eb))
* load external plugin gems without stub recursion ([4926bae](https://github.com/salasebas/better-auth-rb/commit/4926bae7520c17438de25e99cb2155839c177493))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))
* **sso:** harden OIDC endpoint fetching ([#38](https://github.com/salasebas/better-auth-rb/issues/38)) ([177bf8b](https://github.com/salasebas/better-auth-rb/commit/177bf8b847ba4e2a8478d82338b3e4cc7b91932d))
* **sso:** harden provider and SAML lifecycle ([bb81ef0](https://github.com/salasebas/better-auth-rb/commit/bb81ef003359275f3de5080ac708ef12a02f3c56))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

## 0.10.0

- Initial release (extracted from `better_auth-sso` 0.10.0).
