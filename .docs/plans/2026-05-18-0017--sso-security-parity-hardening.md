# SSO Security and Upstream Parity Hardening Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden `packages/better_auth-sso` server-only SSO behavior against blocking HTTP calls, unsafe linking, fragile SAML state/SLO handling, and upstream parity gaps.

**Architecture:** Keep changes scoped to `packages/better_auth-sso`. Reuse the existing modular SSO layout and the newer `BetterAuth::SSO::OIDC::Discovery` pipeline instead of maintaining two discovery implementations.

**Tech Stack:** Ruby 3.2+, Better Auth Ruby plugin APIs, Minitest, `Net::HTTP`, `ruby-saml`, Rack-style endpoint tests.

---

### Task 1: OIDC Discovery and HTTP Hardening

- [x] Replace the live legacy OIDC discovery path in `lib/better_auth/sso/plugin/oidc_discovery.rb` with delegation to `BetterAuth::SSO::OIDC::Discovery`, preserving snake_case config output and mapping `DiscoveryError` to `APIError`.
- [x] Add configurable OIDC HTTP limits, defaulting to 10s open/read timeout and a bounded JSON response size, then apply them to token exchange, UserInfo, JWKS, and discovery HTTP calls.
- [x] Validate manually supplied OIDC endpoints, including `skipDiscovery` configs, against `trusted_origin?` before storing or using them.
- [x] Add regression tests for discovery timeout, 404, invalid JSON, issuer mismatch, untrusted discovered URLs, and bounded token/UserInfo/JWKS failures.

### Task 2: OIDC State and Account Linking

- [x] Prevent OIDC SSO from linking an existing user by email unless the provider is trusted or its verified domain matches the asserted email domain; return the existing `account_not_linked` style flow error.
- [x] Move PKCE `codeVerifier` out of readable signed JWT state into server-side verification storage, keeping the authorization URL state opaque.
- [x] Add regression tests that OIDC existing-user linking is blocked unless trusted/domain-matched and that decoded state no longer exposes `codeVerifier`.

### Task 3: SAML Response Pipeline Hardening

- [x] Use default SSO providers during SAML ACS/callback lookup the same way sign-in already does: exact default provider match first, DB fallback second.
- [x] Validate SAML IdP metadata as upstream does: require a valid `entryPoint`, `idpMetadata.metadata`, or `idpMetadata.singleSignOnService`; reject an empty metadata shell.
- [x] Change SAML replay handling to use only a real assertion ID and redirect with `error=replay_detected`; do not fall back to email as the replay key.
- [x] Delay deletion of SAML `InResponseTo` AuthnRequest records until after response parsing/signature/timestamp validation succeeds.
- [x] Align SAML `trust_email_verified` with upstream: even when enabled, only trust mapped email verification data, not an implicit default.
- [x] Add regression tests for default SAML callback lookup, metadata validation, replay redirects, state retention after invalid responses, and email verification trust behavior.

### Task 4: SAML SLO and Metadata Output

- [x] Harden SAML SLO: reject requests with neither `SAMLRequest` nor `SAMLResponse`, and replace “signature exists” checks with real validation through the configured SAML adapter where available; never delete sessions on invalid SLO messages.
- [x] Escape generated SP metadata XML fields and reject SP metadata requests for non-SAML or invalid SAML providers.
- [x] Add regression tests that missing SLO payloads and fake signatures are rejected with sessions retained, and that SP metadata is escaped and rejects non-SAML providers.

### Task 5: Verification

- [x] Run `rbenv exec bundle exec rake test` in `packages/better_auth-sso`.
- [x] Run `rbenv exec bundle exec standardrb` or the package default rake task.
- [x] Update this plan checklist as tasks complete.

## Assumptions

- Scope is only `packages/better_auth-sso`; no core or framework package changes unless an SSO test helper requires it.
- Public option additions are limited to OIDC timeout/body-size settings and keep backward-compatible defaults.
- Tests assert safe rejection and session preservation only; no exploit instructions or offensive proof-of-concept content should be added.
