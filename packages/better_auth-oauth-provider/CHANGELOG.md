# Changelog

## Unreleased

- Hardened provider authorization, grant, post-login, and client-validation
  paths, with explicit Ruby adaptations documented in tests where applicable.
- Added a checked upstream test inventory for OAuth Provider server behavior.

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-oauth-provider-v0.10.0...better_auth-oauth-provider/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.
* **oauth-provider:** unify OAuth/OIDC/MCP under oauth_provider gem

### Features

* **oauth-provider:** align protocol behavior with upstream ([9217273](https://github.com/salasebas/better-auth-rb/commit/9217273069ffa2c18d256a8c1d9d5487a8d316c1))
* **oauth-provider:** unify OAuth/OIDC/MCP under oauth_provider gem ([7d16def](https://github.com/salasebas/better-auth-rb/commit/7d16def22ea26f753e520e95522568261eca2090))
* **schema:** align migration plugin schema parity ([c0261dc](https://github.com/salasebas/better-auth-rb/commit/c0261dc1e5fd649557cd8a57b92c0609620c3767))


### Bug Fixes

* **auth:** consume single-use state atomically ([07bedc1](https://github.com/salasebas/better-auth-rb/commit/07bedc1c114189e0039a63f2a0cf377658fe457c))
* **ci:** resolve Ruby 3.4 lint, plugin loading, and upstream parity ([ecf5edd](https://github.com/salasebas/better-auth-rb/commit/ecf5edd032eb3695e94456754779656fe017cd7b))
* **ci:** restore package .ruby-version files for setup-ruby ([c18d220](https://github.com/salasebas/better-auth-rb/commit/c18d220065f3cb7cd2504bef7aa407e2c0c027eb))
* load external plugin gems without stub recursion ([4926bae](https://github.com/salasebas/better-auth-rb/commit/4926bae7520c17438de25e99cb2155839c177493))
* **plugins:** enforce organization and device ownership ([1177216](https://github.com/salasebas/better-auth-rb/commit/117721660a4323926456c5c8b0461c77ff5e651f))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

## 0.10.0 - 2026-05-21

- Changed OAuth provider defaults to hash stored client secrets and opaque OAuth tokens, with `store_tokens` support for custom token hashing.
- Hardened token, introspection, and revocation client authentication to enforce the registered auth method and reject public-client introspection/revocation.
- Aligned refresh-token issuance with upstream by requiring `offline_access`, and revoking descendant access tokens when a refresh token is revoked.
- Added no-store token response headers, default JWKS discovery metadata, authorization-code session revalidation, prompt/request-uri validation, MCP verifier error normalization, and OAuth hot-path schema indexes.
- Expanded adapter, authorization, registration, and rate-limit coverage for provider flows.

## 0.7.0 - 2026-05-05

- Fixed OAuth provider consent approval, metadata, issuer normalization, revocation persistence, and endpoint-specific rate limits for hardening parity.
- Changed RP-initiated logout ID token validation to use the hardened HS256 ID token key; old ID tokens signed only with the public client id will no longer validate.
- Hardened OAuth client endpoints, token exchange, introspection, userinfo, and pairwise behavior with expanded parity coverage.

## 0.3.0 - 2026-04-30

- Added upstream-parity support for provider init validation, request URI resolution, prompt handling, consent reference IDs, client references, custom token/id-token claims, scope-specific access-token expiry, M2M token defaults, userinfo JWT verification, and expanded introspection fields.
- Aligned dynamic registration, admin client creation, authorization, consent, token, refresh, revoke, and userinfo behavior with upstream edge cases.
- Expanded OAuth provider upstream parity tests across authorization, metadata, client privileges, pairwise endpoints, organization integration, prompts, rate limits, PKCE/token handling, and userinfo.

## 0.2.0 - 2026-04-29

- Aligned OAuth provider server behavior with upstream `@better-auth/oauth-provider` v1.6.9: upstream-shaped client and consent CRUD routes, server-only admin client routes, discovery metadata auth-method and signing-alg semantics, canonical access-token and consent schema, dynamic-registration PKCE defaults, refresh replay cascade revocation, rotate-secret response shape, and pairwise sector identifiers.
- Added upstream-parity OAuth provider behavior for dynamic client registration controls, PKCE enforcement, consent management, client management, token prefixes, refresh rotation, JWT resource access tokens, pairwise subjects, userinfo claims, introspection/revocation hints, end-session, `/oauth2/continue`, metadata cache headers, conditional JWKS metadata, and rate limits.
- Updated package and docs examples to use executable registration and token exchange flows.

## 0.1.0

- Initial package skeleton for Better Auth OAuth provider.
