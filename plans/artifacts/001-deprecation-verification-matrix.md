# Plan 001 deprecation verification matrix

Target upstream: Better Auth `v1.6.9` at `f484269228b7eb8df0e2325e7d264bb8d7796311`.

Status values:

- `PASS`: current Ruby code/docs match the skip-legacy intent for this row.
- `FAIL`: current Ruby code/docs still expose or document the legacy surface.
- `MIXED`: canonical behavior exists, but legacy compatibility or stale docs remain.

## Upstream TS deprecation scan

Saved in `plans/artifacts/001-upstream-ts-deprecations.txt`.

Observed hits:

- `packages/better-auth/src/plugins/admin/types.ts:82` deprecates `allowImpersonatingAdmins`.
- `packages/better-auth/src/plugins/oidc-provider/index.ts:278` and `:290` deprecate `oidc-provider`.
- `packages/better-auth/src/plugins/email-otp/routes.ts:795` and `:799` deprecate `/forget-password/email-otp`.
- `packages/better-auth/src/plugins/oidc-provider/client.ts:6` deprecates the OIDC client plugin.

## P0 - Provider consolidation (breaking OK)

| ID | Upstream canonical | Do NOT support in Ruby | Upstream evidence | Ruby evidence | Status | Required action | Owner plan |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D-01 | `BetterAuth::Plugins.oauth_provider` only | `Plugins.oidc_provider`, `Plugins.mcp` as supported plugins | `plugins/oidc-provider.mdx:6-8`, `plugins/mcp.mdx:8-16`, `plugins/oauth-provider.mdx:2045-2047`, TS `oidc-provider/index.ts:278-290` | `packages/better_auth/lib/better_auth/plugins.rb:63-70` raises removed-factory errors; `packages/better_auth/test/better_auth/plugin_loader_test.rb:49-58` verifies. `docs-site/content/docs/plugins/mcp.mdx:1-10` still exists as a docs page; `docs-site/content/docs/plugins/oauth-provider.mdx:189` incorrectly says MCP support lives in the core MCP plugin. | FAIL | Keep removed factories, remove stale supported-doc signals and stale MCP sentence. | 011 / 002 follow-up |
| D-02 | `/oauth2/*` routes | `/mcp/register`, `/mcp/authorize`, `/mcp/token`, `/mcp/userinfo`, `/mcp/jwks` | `plugins/oauth-provider.mdx:2135-2144`; `plugins/mcp.mdx:8-16` | Core MCP implementation files are absent; `packages/better_auth/test/better_auth/plugins/open_api_test.rb:589-595` refutes `/mcp/` OpenAPI paths. `packages/better_auth-oauth-provider/README.md:197-198` documents `/oauth2/*` migration. | PASS | Keep `/mcp/*` legacy routes absent. | 002 |
| D-03 | `/oauth2/introspect` | `/mcp/get-session` | `plugins/oauth-provider.mdx:724`, `plugins/oauth-provider.mdx:2144` | `packages/better_auth-oauth-provider/README.md:198` says use introspection instead of `/mcp/get-session`; grep found no `get_mcp_session` public API. | PASS | Keep `/mcp/get-session` absent. | 002 |
| D-04 | `consent_page` required | `get_consent_html` | `plugins/oauth-provider.mdx:2055-2056`; `plugins/oidc-provider.mdx:24-26` marks OIDC unstable | `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider.rb:40-43` has `consent_page`; grep found no `get_consent_html` in Ruby plugin code/docs. | PASS | Keep raw consent HTML unsupported. | 002 |
| D-05 | PKCE default S256; per-client `require_pkce: false` only | Global `require_pkce` option | `plugins/oauth-provider.mdx:1168-1200`, `plugins/oauth-provider.mdx:1808-1812`, `plugins/oauth-provider.mdx:2057-2058` | `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider/register.rb:25` defaults registered clients to PKCE; schema has per-client `requirePKCE` at `schema.rb:38`; no global oauth-provider `require_pkce` config was found. | PASS | Keep PKCE opt-out per client only. | 002 |
| D-06 | `client_registration_default_scopes` array | MCP/OIDC `defaultScope` string | `plugins/oauth-provider.mdx:2054`; `plugins/mcp.mdx:233-236`; `oidc-provider/types.ts:48` | `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider.rb:47` and `register.rb:33` use `client_registration_default_scopes`; no `defaultScope` config was found in Ruby oauth-provider. | PASS | Keep array-style scope defaults. | 002 |
| D-07 | `store_client_secret: "hashed"` default | Plain client secrets by default | `plugins/oauth-provider.mdx:1234-1238`, `plugins/oauth-provider.mdx:2060`; OIDC old default at `oidc-provider/index.ts:312` | `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider.rb:52` defaults to `"hashed"`; validation at `oauth_provider.rb:113-119` guards unsafe mode combinations. | PASS | Keep hashed default and migration docs. | 002 / 011 |
| D-08 | Tables `oauthClient`, split refresh tokens | `oauthApplication`, monolithic access token table | `plugins/oauth-provider.mdx:1621-1627`, `plugins/oauth-provider.mdx:2066-2107`; `plugins/oidc-provider.mdx:444-521`, `:536-588` | `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider/schema.rb:9-44` defines `oauthClient`; `schema.rb:44-58` defines `oauthRefreshToken`; `packages/better_auth-oauth-provider/test/better_auth/oauth_provider/oauth_test.rb:10-16` refutes `oauthApplication`. | PASS | Keep new schema and migration guidance. | 002 / 012 |
| D-09 | JWT plugin on by default for oauth-provider | Disable JWT unless intentional | `plugins/oauth-provider.mdx:589-591`, `plugins/oauth-provider.mdx:2061` | `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider.rb:203-205` requires JWT plugin unless disabled; `jwt_plugin_requirement_test.rb:8-24` verifies required/default and explicit disable paths. | PASS | Keep explicit `disable_jwt_plugin` only for intentional fallback. | 002 |

## P1 - Core/plugin legacy options

| ID | Canonical API | Legacy to drop from docs/new code | Upstream evidence | Ruby evidence | Status | Required action | Owner plan |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D-10 | `/email-otp/request-password-reset` | `/forget-password/email-otp` | `plugins/email-otp.mdx:187-199`; TS `email-otp/routes.ts:795-799` | `packages/better_auth/test/better_auth/plugins/email_otp_test.rb:365-368` verifies the legacy route returns 404; grep found no route registration in `packages/better_auth/lib`. | PASS | Keep legacy route absent; remove `SKIP_PATHS` exception later if endpoint-registry parity no longer needs it. | 005 / 011 |
| D-11 | Admin role permission `impersonate-admins` | `allow_impersonating_admins` | `plugins/admin.mdx:387-397`; TS `admin/types.ts:82` | `packages/better_auth/lib/better_auth/plugins/admin.rb:415-416` still reads `allow_impersonating_admins`; `docs-site/content/docs/plugins/admin.mdx:52-58` still documents it. | FAIL | Remove or stop documenting the legacy option; document permission model. | 011 / future admin cleanup |
| D-12 | `organization_hooks` | `organization_creation` hooks | `plugins/organization.mdx:153-158`, `plugins/organization.mdx:213-216` | `packages/better_auth/lib/better_auth/plugins/organization.rb:1184-1185` uses `organization_hooks`; grep found no `organization_creation` legacy option in Ruby code/docs. | PASS | Keep `organization_hooks` only. | 015 / 011 |
| D-13 | API key `referenceId` in responses/schema | `userId` field on apikey model responses | `plugins/api-key/reference.mdx:472-476`, `plugins/api-key/reference.mdx:572-594` | `packages/better_auth-api-key/lib/better_auth/api_key/schema.rb:18` uses `referenceId`; `utils.rb:39-40` emits `referenceId`. Legacy fallback remains in `types.rb:10-15` and `adapter.rb:75-77`; OpenAPI response still includes `userId` at `routes/index.rb:270-291`. | MIXED | Keep migration fallback only if intentional; remove `userId` from public response docs/schema when no longer needed. | 011 / api-key follow-up |
| D-14 | Versioned `secrets` | Documenting bare `secret` as primary | `reference/options.mdx:205-211`, `reference/security.mdx:12-18` | Runtime supports `secrets` in `packages/better_auth/lib/better_auth/configuration.rb:82-86`, but local docs still lead with `secret` at `docs-site/content/docs/reference/options.mdx:65-69` and call `BETTER_AUTH_SECRETS` optional at `security.mdx:8-12`. | FAIL | Make versioned `secrets` the primary docs path and describe bare `secret` as legacy/decrypt fallback. | 013 |

## P2 - Unstable / future deprecation (document gap, do not port legacy)

| ID | Item | Upstream evidence | Ruby evidence/status | Ruby action | Owner plan |
| --- | --- | --- | --- | --- | --- |
| D-15 | `allowUnauthenticatedClientRegistration` | `plugins/oauth-provider.mdx:421-424`, `plugins/oauth-provider.mdx:1090-1095` | `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider.rb:45-47` defaults unauthenticated registration off; `register.rb:16-20` gates unauthenticated DCR. Local docs list the option at `docs-site/content/docs/plugins/oauth-provider.mdx:34` and `:124` without the upstream future-deprecation warning. Status: MIXED. | Keep option if needed for MCP DCR, but mark unstable/future-deprecated in docs. | 011 |
| D-16 | Agent Auth plugin | `plugins/agent-auth.mdx:8-10` says not yet stable | Inventory classifies `plugins/agent-auth.mdx` as `SKIP_UNPORTED`; no Ruby package was found. Status: PASS. | Exclude until upstream stability callout is removed. | 008 / 011 |
| D-17 | OAuth Provider gaps: introspection bearer, `sector_identifier_uri`, protected resource helpers | `plugins/oauth-provider.mdx:724`, `plugins/oauth-provider.mdx:1449-1454`, `plugins/oauth-provider.mdx:2145` | Ruby README says resource helpers exist at `packages/better_auth-oauth-provider/README.md:186`, while docs-site says no equivalent at `docs-site/content/docs/plugins/oauth-provider.mdx:187-189`; Ruby MCP helper exists at `oauth_provider/mcp.rb:72-78`. Status: FAIL docs consistency. | Document current support and `<UnderDevelopment />`-style gaps explicitly; remove stale core-MCP statement. | 011 |
| D-18 | SSO deprecated SAML algorithms | `plugins/sso.mdx:1162-1181`, `plugins/sso.mdx:1206-1211`, schema at `plugins/sso.mdx:1672-1680` | Local SSO docs are a short stub at `docs-site/content/docs/plugins/sso.mdx:1-18`; Ruby provider utility exposes algorithm fields at `packages/better_auth-sso/lib/better_auth/sso/plugin/provider_utils.rb:168-174`, but no `on_deprecated` evidence was found in the scanned Ruby paths. Status: FAIL. | Ensure Ruby warn/reject/allow behavior matches upstream or document unsupported gap. | 011 / SSO follow-up |
| D-19 | `experimentalJoins` | `concepts/database.mdx:994-1011` | Runtime default is off through `normalize_experimental(nil)` at `configuration.rb:100` and `configuration.rb:353-357`; local docs mark `experimental: {joins: true}` at `docs-site/content/docs/concepts/database.mdx:386-398`. Status: PASS. | Keep default off and experimental label. | 009 |

## Maintainer sign-off checklist

### Provider (breaking changes approved)
- [ ] Remove `BetterAuth::Plugins.mcp` and `BetterAuth::Plugins.oidc_provider` from public docs and plugin loader (Plan 002)
- [ ] Remove `/mcp/*` legacy routes from codebase (Plan 002)
- [ ] Expand oauth-provider docs from upstream oauth-provider.mdx including migration sections (Plans 011/002)
- [ ] Do not add oidc-provider.mdx to docs-site

### Core legacy endpoints/options
- [ ] Remove `/forget-password/email-otp` route (keep upstream compat shim only if explicitly required — default: remove)
- [ ] Stop documenting `allow_impersonating_admins`; document permission model
- [ ] Port/document `organization_hooks` only
- [ ] Confirm API key public responses use `referenceId`

### Explicit non-goals
- [ ] Do not port Agent Auth until upstream stability callout removed
- [ ] Do not port MCP plugin docs as supported feature
- [ ] Do not port OIDC Provider plugin docs as supported feature
- [ ] Do not port test-utils, infrastructure, JS integrations
