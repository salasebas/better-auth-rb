# Implementation Plans

Index for active improvement plans. Each executor must read the assigned plan
fully before starting, honor its STOP conditions, and update the status row when
done.

Status values: TODO | IN PROGRESS | DONE | BLOCKED | REJECTED.

## Current Inventory

| Plan | File | Title | Depends on | Status |
| --- | --- | --- | --- | --- |
| 001 | `001-upstream-docs-deprecation-audit-and-skip-legacy.md` | Upstream docs deprecation audit & skip-legacy verification | - | DONE |
| 002 | `002-oauth-provider-unified-parity.md` | OAuth provider unified parity | - | DONE |
| 003 | `003-oauth-provider-parity-gaps-and-tests.md` | OAuth provider parity gaps, JWT requirement, tests | 002 | DONE |
| 004 | `004-add-core-i18n-plugin.md` | Core i18n plugin (`BetterAuth::Plugins.i18n`) | - | DONE |
| 005 | `005-endpoint-contract-cleanup.md` | Endpoint contract cleanup | 001 | DONE |
| 006 | `006-upstream-auth-api-naming-parity.md` | Upstream `auth.api` naming parity (Ruby idiomatic) | 005 | DONE |
| 007 | `007-stable-resource-oriented-http-api.md` | Stable resource-oriented HTTP API | 005; after 006 rec. | TODO |
| 008 | `008-docs-parity-foundation.md` | Docs parity foundation (tooling + manifest) | 001 rec. | DONE |
| 009 | `009-docs-concepts-and-getting-started.md` | Concepts & getting started finish-pass | 008 | DONE |
| 010 | `010-docs-adapters-authentication.md` | Adapters & authentication finish-pass | 008 | DONE |
| 011 | `011-docs-plugins-parity.md` | Supported plugins copy-first parity | 008, 009 rec. | TODO |
| 012 | `012-docs-schema-endpoint-resources.md` | Generated database schemas and endpoint resources | 008, 011 | TODO |
| 013 | `013-docs-reference-guides.md` | Reference, guides & errors | 008 | TODO |
| 014 | `014-organization-membership-limit-parity.md` | Organization membership limit parity | - | TODO |
| 015 | `015-organization-lifecycle-hooks-parity.md` | Organization lifecycle and hooks parity | 014 rec. | TODO |
| 016 | `016-include-oidc-saml-in-workspace-tasks.md` | Include OIDC and SAML packages in workspace tasks | - | TODO |
| 017 | `017-migration-schema-parity.md` | Migration schema parity across SQL, MongoDB, and integrations | - | TODO |
| 018 | `018-core-social-providers-upstream-parity.md` | Core social providers upstream parity matrix | - | DONE |
| 019 | `019-generic-oauth-other-social-providers-parity.md` | Generic OAuth other social providers parity | - | DONE |

## Done

- **002** OAuth provider unified parity.
- **003** OAuth provider parity gaps, JWT requirement, tests.
- **004** Core i18n plugin.
- **005** Endpoint contract cleanup.
- **006** Upstream `auth.api` naming parity.
- **018** Core social providers upstream parity matrix.
- **019** Generic OAuth other social providers parity.

## Pending

- **007** Stable resource-oriented HTTP API. This was missing as a file before
  renumbering; it now exists as a placeholder and still needs a full executable
  implementation plan before coding.
- **009-013** Docs parity initiative.
- **014** Organization membership limit parity.
- **015** Organization lifecycle and hooks parity.
- **016** Include OIDC and SAML packages in workspace tasks.
- **017** Migration schema parity across SQL, MongoDB, and integrations.

## Parallel Execution Groups

Group A, docs planning and docs copy work:

- Run **001** first if the docs initiative needs fresh exclusion/deprecation
  rules.
- After **008** is done, **009**, **010**, and **011** can run mostly in
  parallel. Coordinate links and plugin support tables.
- **012** should wait for **011** unless the supported plugin list is manually
  finalized.
- **013** can run after **008**, but must not expand `reference/resources.mdx`
  because **012** owns generated schema and endpoint resources.

Group B, HTTP/API cleanup:

- **005** and **006** are already done.
- **007** can start only after its placeholder is expanded into a real plan. It
  depends on **005** and should use **006** as the naming baseline.

Group C, organization plugin parity:

- Run **014** before **015** if possible. Both touch organization membership and
  invitation flows, so parallel execution requires tight file-level coordination.

Group D, independent infrastructure/runtime work:

- **016** can run independently.
- **017** can run independently of plugin runtime parity, but prefer it before
  adding more schema-bearing plugins.
- **018** and **019** are already done. They were independent of the docs
  initiative, but future social-provider changes should check both plans.

## Recommended Order

If executing remaining work serially, use:

**001 -> 008 -> 009/010/011 -> 012 -> 013 -> 014 -> 015 -> 016 -> 017 -> 007**

Plan **007** is intentionally last until it has a full plan, because it is a
breaking HTTP route redesign.

## Notes For Executors

- Do not modify `reference/upstream-src/**`.
- Do not mark docs parity plans DONE without explicit maintainer approval.
- Keep core tests in Minitest under `packages/better_auth/test`.
- Do not use `mcp` or upstream `oidc-provider` as supported docs targets.
- Do not rename standards-owned SCIM, OAuth/OIDC/device, SAML, or WebAuthn
  protocol routes and field names while cleaning endpoint contracts.
- Prefer generator output from RubyAuth (`BetterAuth::Schema`,
  `BetterAuth::Schema::SQL`, and OpenAPI metadata) over manually mapping tables,
  fields, or endpoints.
- Plans **018** and **019** cover auth-runtime behavior. Do not treat provider
  factory existence as sufficient parity for either plan.
- Plans **018** and **019** are scoped to Better Auth upstream `v1.6.9` at commit
  `f484269228b7eb8df0e2325e7d264bb8d7796311`.

## Findings Considered And Rejected

- **Auto-enable JWT plugin when oauth-provider loads**: upstream and maintainer
  intent require explicit registration; init must fail with `jwt_config` instead.
- **Full `sector_identifier_uri` implementation**: upstream v1.6.9 also rejects
  multi-host pairwise without it; message alignment only in OAuth plan 003.
- **docs-site Support Boundary refresh**: deferred per maintainer; OAuth plan
  003 excluded docs-site entirely.
- **Broad REST rewrite of action routes**: rejected for Plan 005's cleanup
  scope, but explicitly planned as pre-stable breaking API work in Plan 007.
- **Legacy `_o_auth_` / `_o_auth2_` Ruby registry segments**: rejected in Plan
  006; rename to compact `oauth` / `oauth2` (e.g. `create_oauth_client`).
- **Captcha missing-secret note in upstream parity metadata**: rejected during
  the 2026-06-21 plugin audit. Upstream v1.6.9 throws from `validateCaptcha`
  when the secret key is absent and returns a 500 error; Ruby's
  `UNKNOWN_ERROR` 500 behavior and tests match that observable path.
- **Magic-link missing-token redirect note in upstream parity metadata**:
  rejected during the 2026-06-21 plugin audit. Upstream tests cover invalid
  token redirect behavior, and Ruby already has invalid-token redirect coverage;
  missing required query parameters are validation errors before handler logic.
- **Treat social provider parity as complete because all factories exist**:
  rejected in Plan 018; several providers require upstream-specific token auth,
  PKCE, ID-token verification, profile-fetch, or nil-handling behavior.
- **Fold generic OAuth other-social-providers into the built-in provider audit**:
  rejected in Plan 019; generic OAuth helpers and docs have separate runtime and
  documentation contracts.

Generated by improve skill on 2026-06-16 (OAuth plan 003 at commit `2ce7a4a`).
Updated by improve skill on 2026-06-21 (plugin parity audit at commit `33b07f4`).
Updated by improve skill on 2026-06-21 (social provider plans 018-019 at commit `33b07f4`).
Renumbered from the previous 019-035 range to 001-019 on 2026-06-21.
