# Plan 019: Make OAuth Provider the Only OAuth/OIDC/MCP Provider Surface

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report; do not improvise. When done, update the status row for this plan in
> `plans/README.md` unless a reviewer told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 0d19370..HEAD -- packages/better_auth packages/better_auth-oauth-provider packages/better_auth-oidc packages/openauth-oidc docs-site/content/docs/plugins docs-site/lib/plugins.ts docs-site/components/sidebar-content.tsx README.md Gemfile Rakefile plans`
>
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against live code before proceeding. A mismatch is a
> STOP condition unless it is only line-number drift and the named symbols still
> have the same behavior.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: HIGH
- **Depends on**: none
- **Category**: migration
- **Planned at**: commit `0d19370`, 2026-06-16

## Why this matters

Better Auth upstream now presents `@better-auth/oauth-provider` as the provider
plugin that includes OAuth 2.1, OIDC compatibility, MCP support, dynamic client
registration, resource-server helpers, and migration guidance. The Ruby port
currently exposes `BetterAuth::Plugins.oidc_provider` and `BetterAuth::Plugins.mcp`
as separate core plugin surfaces while also shipping `better_auth-oauth-provider`.
That split creates conflicting docs, duplicated models/routes, and unclear user
choice. Breaking changes are acceptable for this task: after this lands, Ruby
users should configure provider behavior through `BetterAuth::Plugins.oauth_provider`
only, and MCP/OIDC provider behavior should be features of that plugin, not
separately supported plugins.

## Current state

- `/Users/sebastiansala/projects/better-auth/AGENTS.md` says this is a Ruby port
  of Better Auth, target upstream `v1.6.9`, and shared auth behavior belongs in
  `packages/better_auth`; external plugin packages provide integration.
- Root verification commands are `bundle exec rake ci`, `bundle exec rake test`,
  and `bundle exec standardrb`. Core uses Minitest; adapters/plugins use RSpec.
- `docs-site/AGENTS.md` says docs examples should be Ruby, incomplete features
  should be marked with `<UnderDevelopment />`, and docs verification is
  `cd docs-site && pnpm lint` plus `cd docs-site && pnpm build`.
- Current upstream docs at https://better-auth.com/docs/plugins/oauth-provider
  describe OAuth Provider as OAuth 2.1 with OIDC compatibility and MCP enabled,
  with authorization-code, refresh-token, and client-credentials grants. The
  docs also require OIDC userinfo/id_token/logout behavior, dynamic client
  registration, JWT/JWKS compatibility, introspection/revocation, protected
  resource metadata for MCP, and migration guidance from both OIDC Provider and
  MCP Plugin.

Relevant current Ruby code excerpts:

- `packages/better_auth/lib/better_auth/plugin_loader.rb:31-35` currently lists
  separate core loaders:

  ```ruby
  oauth_protocol: "plugins/oauth_protocol",
  oidc_provider: "plugins/oidc_provider",
  oauth_provider: "plugins/oauth_provider",
  device_authorization: "plugins/device_authorization",
  mcp: "plugins/mcp",
  ```

- `packages/better_auth/lib/better_auth/plugin_loader.rb:50-52` wires separate
  dependencies:

  ```ruby
  oidc_provider: %i[oauth_protocol],
  mcp: %i[oauth_protocol],
  device_authorization: %i[oauth_protocol]
  ```

- `packages/better_auth/lib/better_auth/plugin_loader.rb:80-83` and `:95-98`
  expose `"oidc-provider"`, `"mcp"`, `OIDCProvider`, and `MCP` as public lazy
  load targets.
- `packages/better_auth/lib/better_auth/plugins/oidc_provider.rb:8-10` only
  deprecates the old plugin, but `:48-79` still implements and returns a live
  plugin with id `"oidc-provider"`.
- `packages/better_auth/lib/better_auth/plugins/mcp.rb:32-40` still implements
  and returns a live plugin with id `"mcp"`, and `:43-61` exposes MCP-specific
  endpoints including legacy `/mcp/*` aliases.
- `packages/better_auth/lib/better_auth/plugins/oauth_provider.rb:9-10` is the
  correct core shim: it delegates `BetterAuth::Plugins.oauth_provider` to the
  external gem `better_auth-oauth-provider`.
- `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider.rb:38-76`
  implements the external plugin with id `"oauth-provider"` and already includes
  many upstream-shaped defaults. It requires `oauth_provider/mcp` at line 12 and
  `oauth_provider/client_resource` at line 7, but the README says resource
  client and MCP helpers are future work.
- `packages/better_auth-oauth-provider/README.md:178-184` is now wrong for the
  target behavior:

  ```markdown
  Upstream `oauthProviderResourceClient` and MCP protected-resource helpers remain future API-boundary work for Ruby.
  ...
  OIDC provider remains a core `better_auth` plugin because upstream still exposes it from `better-auth/plugins`.
  ```

- `docs-site/content/docs/plugins/index.mdx:30` lists OIDC Provider as a core
  plugin, and `:52` says MCP is upstream-only. Both must change.
- `docs-site/content/docs/plugins/meta.json:26-27` includes both
  `"oauth-provider"` and `"oidc-provider"`.
- `docs-site/content/docs/plugins/oidc-provider.mdx:11-18` documents
  `BetterAuth::Plugins.oidc_provider`; this page should be removed or replaced
  with migration-only redirect content that sends users to OAuth Provider.
- `docs-site/content/docs/plugins/oauth-provider.mdx:16-42` is only a stub. It
  does not contain the current upstream OAuth Provider docs surface.
- `Gemfile:21` and `Gemfile:41` still include `better_auth-oidc` and
  `openauth-oidc`. Be careful: `better_auth-oidc` is also used by the SSO
  relying-party package, not by OAuth Provider. Do not delete SSO's OIDC
  relying-party implementation unless the user explicitly asks for SSO changes.

Upstream files to read before editing implementation:

- `reference/upstream-src/1.6.9/repository/packages/oauth-provider/src/index.ts`
- `reference/upstream-src/1.6.9/repository/packages/oauth-provider/src/oauth.ts`
- `reference/upstream-src/1.6.9/repository/packages/oauth-provider/src/client-resource.ts`
- `reference/upstream-src/1.6.9/repository/packages/oauth-provider/src/mcp.ts`
- `reference/upstream-src/1.6.9/repository/packages/oauth-provider/src/metadata.ts`
- `reference/upstream-src/1.6.9/repository/packages/oauth-provider/src/register.ts`
- `reference/upstream-src/1.6.9/repository/packages/oauth-provider/src/token.ts`
- `reference/upstream-src/1.6.9/repository/packages/oauth-provider/src/oauthClient/endpoints.ts`
- `reference/upstream-src/1.6.9/repository/packages/oauth-provider/src/schema.ts`
- `reference/upstream-src/1.6.9/repository/packages/oauth-provider/src/types/index.ts`
- `reference/upstream-src/1.6.9/repository/docs/content/docs/plugins/oauth-provider.mdx`

Repo conventions to match:

- Ruby files use `# frozen_string_literal: true`, StandardRB, two spaces, snake_case.
- Minitest files under plugin packages use `require_relative "../../test_helper"` and direct observable route/API behavior.
- The OAuth Provider package already uses focused test files under
  `packages/better_auth-oauth-provider/test/better_auth/oauth_provider/`; add new
  tests there instead of growing the legacy monolithic test unless the existing
  test helper makes that unavoidable.
- Do not add dependencies. Existing `jwt`, `rack`, Minitest, and BetterAuth
  helpers are enough.

## Commands you will need

| Purpose | Command | Expected on success |
| --- | --- | --- |
| Core targeted tests | `cd packages/better_auth && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest test/better_auth/plugin_loader_test.rb test/better_auth/plugins/external_plugin_shim_test.rb test/better_auth/plugins/open_api_test.rb` | exit 0 |
| OAuth Provider tests | `cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test` | exit 0 |
| Core package CI | `cd packages/better_auth && BUNDLE_GEMFILE=Gemfile bundle exec rake ci` | exit 0 |
| Workspace lint | `bundle exec standardrb` | exit 0 |
| Docs typecheck | `cd docs-site && pnpm lint` | exit 0 |
| Docs build | `cd docs-site && pnpm build` | exit 0 |
| Workspace CI | `bundle exec rake ci` | exit 0 |

If `pnpm` dependencies are missing, run `cd docs-site && pnpm install` only if
the operator approves installing/updating local dependencies. Do not commit
changes under `reference/upstream-src/**`.

## Suggested executor toolkit

- Use the `systematic-debugging` skill for test failures.
- Use the `test-driven-development` skill before implementation changes.
- Use `design-taste-frontend` only if touching docs-site UI components beyond
  MDX/navigation metadata. This plan should not require visual redesign.

## Scope

**In scope**:

- `packages/better_auth/lib/better_auth/plugin_loader.rb`
- `packages/better_auth/lib/better_auth/plugins/oauth_provider.rb`
- `packages/better_auth/lib/better_auth/plugins/oidc_provider.rb`
- `packages/better_auth/lib/better_auth/plugins/mcp.rb`
- `packages/better_auth/lib/better_auth/plugins/mcp/**`
- `packages/better_auth/test/better_auth/plugin_loader_test.rb`
- `packages/better_auth/test/better_auth/plugins/external_plugin_shim_test.rb`
- `packages/better_auth/test/better_auth/plugins/open_api_test.rb`
- `packages/better_auth/test/better_auth/plugins/oidc_provider_test.rb`
- `packages/better_auth/test/better_auth/plugins/mcp/**`
- `packages/better_auth/test/support/upstream_server_parity.rb`
- `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider.rb`
- `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider/**`
- `packages/better_auth-oauth-provider/test/better_auth/oauth_provider/**`
- `packages/better_auth-oauth-provider/test/support/**`
- `packages/better_auth-oauth-provider/README.md`
- `docs-site/content/docs/plugins/oauth-provider.mdx`
- `docs-site/content/docs/plugins/oidc-provider.mdx`
- `docs-site/content/docs/plugins/meta.json`
- `docs-site/content/docs/plugins/index.mdx`
- `docs-site/lib/plugins.ts`
- `docs-site/components/sidebar-content.tsx` only if it has hard-coded plugin links
- Root `README.md`, `Gemfile`, and `Rakefile` only if they mention provider
  plugin support or run deleted core MCP/OIDC provider tests.

**Out of scope**:

- `packages/better_auth-oidc/**` and `packages/openauth-oidc/**` as SSO
  relying-party packages. They are about signing in through external OIDC IdPs,
  not making this app an OIDC/OAuth provider. Do not delete them just because
  they contain "oidc".
- `packages/better_auth-sso/**`, except for docs wording if it falsely claims
  provider behavior.
- `packages/better_auth-saml/**` and `packages/openauth-saml/**`.
- Browser client packages; Ruby has no Better Auth browser client layer.
- Any change to upstream reference files under `reference/upstream-src/**`.

## Git workflow

- Branch: `feat/oauth-provider-unified-parity`
- Commit message style from recent history: Conventional Commits, for example
  `feat(core): add OAuth2 provider support`.
- Suggested commits: one core breaking surface commit, one OAuth Provider parity
  commit, one docs commit. Do not push or open a PR unless instructed.

## Steps

### Step 1: Characterize and lock the breaking public-surface contract

Add tests before deleting behavior:

1. In `packages/better_auth/test/better_auth/plugin_loader_test.rb`, replace
   `test_oidc_provider_loads_only_when_factory_is_called` with tests asserting:
   - `BetterAuth::Plugins.respond_to?(:oauth_provider)` is true after
     `require "better_auth"`.
   - `BetterAuth::Plugins.respond_to?(:oidc_provider)` is false, or calling it
     raises `NoMethodError`/`ArgumentError` with a message that says use
     `BetterAuth::Plugins.oauth_provider`.
   - `BetterAuth::Plugins.respond_to?(:mcp)` is false, or calling it raises
     `NoMethodError`/`ArgumentError` with a message that says use
     `BetterAuth::Plugins.oauth_provider`.
   - `BetterAuth::Plugins.const_defined?(:OIDCProvider, false)` and
     `BetterAuth::Plugins.const_defined?(:MCP, false)` remain false after boot.
2. In `packages/better_auth/test/better_auth/plugins/external_plugin_shim_test.rb`,
   keep the oauth_provider shim assertion and add negative coverage that core no
   longer treats `oidc_provider` or `mcp` as supported external shims.
3. In `packages/better_auth/test/better_auth/plugins/open_api_test.rb`, remove
   examples that construct `BetterAuth::Plugins.oidc_provider` or
   `BetterAuth::Plugins.mcp`. Replace them with `BetterAuth::Plugins.oauth_provider`
   plus `require "better_auth/oauth_provider"` only if the test's purpose is
   OpenAPI behavior for OAuth Provider. If OpenAPI only tests core plugin
   discovery, assert that OIDC/MCP provider endpoints are absent from core.
4. Move any still-useful behavioral expectations from
   `packages/better_auth/test/better_auth/plugins/oidc_provider_test.rb` and
   `packages/better_auth/test/better_auth/plugins/mcp/**` into the OAuth Provider
   package test suite if they cover behavior not already tested there. Mark the
   original core tests deleted.

**Verify**:
`cd packages/better_auth && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest test/better_auth/plugin_loader_test.rb test/better_auth/plugins/external_plugin_shim_test.rb test/better_auth/plugins/open_api_test.rb`
should fail only because implementation still exposes the old surfaces.

### Step 2: Remove separate core `oidc-provider` and `mcp` support

1. Edit `packages/better_auth/lib/better_auth/plugin_loader.rb`:
   - Remove `oidc_provider: "plugins/oidc_provider"` and `mcp: "plugins/mcp"`
     from `PLUGIN_FILES`.
   - Remove `oidc_provider` and `mcp` entries from `PLUGIN_DEPENDENCIES`.
   - Remove `"oidc-provider" => :oidc_provider` and `"mcp" => :mcp` from
     `PLUGIN_ID_TO_LOADER`.
   - Remove `OIDCProvider: :oidc_provider` and `MCP: :mcp` from
     `NESTED_MODULE_LOADERS`.
   - Keep `oauth_protocol` if `device_authorization` or OAuth Provider internals
     still need it.
   - Keep `oauth_provider: "plugins/oauth_provider"` and its external gem shim.
2. Delete `packages/better_auth/lib/better_auth/plugins/oidc_provider.rb`.
3. Delete `packages/better_auth/lib/better_auth/plugins/mcp.rb` and
   `packages/better_auth/lib/better_auth/plugins/mcp/**`.
4. Delete or update all core tests that only validate the removed plugins.
   Useful assertions should live under `packages/better_auth-oauth-provider/test`.
5. Update `packages/better_auth/test/support/upstream_server_parity.rb` so
   upstream `plugins/oidc-provider/**` and `plugins/mcp/**` are classified as
   superseded by `packages/oauth-provider`, not as active core owners. Do not
   leave owner paths pointing to deleted core test files.

**Verify**:
`rg -n "BetterAuth::Plugins\\.(oidc_provider|mcp)|plugins/oidc_provider|plugins/mcp|OIDCProvider|Plugins::MCP|\"oidc-provider\" =>|\"mcp\" =>" packages/better_auth`
should return no live implementation references. Test fixture strings are okay
only if they explicitly assert removal/migration.

Then run:
`cd packages/better_auth && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest test/better_auth/plugin_loader_test.rb test/better_auth/plugins/external_plugin_shim_test.rb test/better_auth/plugins/open_api_test.rb`
Expected: exit 0.

### Step 3: Close OAuth Provider server parity gaps documented upstream

Read the upstream files listed in "Current state" before this step. Then update
`packages/better_auth-oauth-provider` so `BetterAuth::Plugins.oauth_provider`
is the only provider plugin and covers the documented upstream surface.

Required behavior checklist:

- OAuth/OIDC metadata:
  - `/.well-known/oauth-authorization-server` returns OAuth metadata.
  - `/.well-known/openid-configuration` returns OIDC metadata when `openid` is
    configured and 404s when it is not.
  - Metadata includes issuer, authorize/token/register/introspect/revoke,
    userinfo, end-session, scopes, claims, grant types, S256 PKCE, auth methods,
    authorization response `iss` support, JWKS URI when JWT plugin is active,
    and cache headers.
  - If current docs require mounted handlers to support issuer-path well-known
    URLs, add Ruby route/helper support or clear docs explaining the Ruby mount
    equivalent.
- OAuth clients and consent:
  - Keep upstream-shaped routes:
    `/oauth2/get-client`, `/oauth2/public-client`,
    `/oauth2/public-client-prelogin`, `/oauth2/get-clients`,
    `/oauth2/create-client`, `/admin/oauth2/create-client`,
    `/oauth2/update-client`, `/admin/oauth2/update-client`,
    `/oauth2/client/rotate-secret`, `/oauth2/delete-client`,
    `/oauth2/get-consent`, `/oauth2/get-consents`,
    `/oauth2/update-consent`, `/oauth2/delete-consent`.
  - Because breaking changes are allowed, remove old legacy aliases such as
    `/oauth2/client/:id`, `/oauth2/clients`, `PATCH /oauth2/client`,
    `DELETE /oauth2/client`, and legacy consent aliases unless a test documents
    a deliberate temporary migration window.
  - Implement `cached_trusted_clients` matching upstream: trusted client IDs are
    cached after lookup and cannot be updated, deleted, or rotated through CRUD
    endpoints. Use Ruby naming but accept camelCase aliases if existing options
    already do.
  - Support `client_registration_client_secret_expiration` for dynamically
    registered confidential clients.
  - Preserve `client_reference` and `client_privileges`; add tests if any branch
    is currently only covered in the monolithic file.
- Token behavior:
  - Authorization-code grant requires S256 PKCE by default, includes `iss` on
    authorization responses, and supports `prompt=login`, `prompt=consent`,
    `prompt=select_account`, `prompt=create`, and `prompt=none`.
  - Refresh tokens require `offline_access`, rotate on refresh, preserve
    `auth_time`, and revoke descendant access tokens on replay/revocation.
  - Client credentials grant rejects OIDC scopes and returns machine tokens for
    allowed resource scopes.
  - `valid_audiences` controls JWT access-token audiences; UserInfo is added
    when `openid` is granted.
  - `custom_token_response_fields`, `custom_access_token_claims`,
    `custom_id_token_claims`, and `custom_user_info_claims` receive the upstream
    context values and cannot override pinned OAuth fields.
  - Add `format_refresh_token` support with `encrypt` and `decrypt` callbacks.
    Prefix handling should wrap the formatted token exactly once.
  - Add `generate_client_id`, `generate_client_secret`,
    `generate_opaque_access_token`, and `generate_refresh_token` callbacks if
    missing. These correspond to upstream custom generators.
- MCP/resource-server behavior:
  - `BetterAuth::Plugins::OAuthProvider::MCP.mcp_handler` or a clearly named
    Ruby equivalent must verify bearer access tokens and convert 401s into
    `WWW-Authenticate: Bearer resource_metadata="..."` challenges.
  - Add a resource-client helper equivalent to upstream
    `oauthProviderResourceClient` with:
    `verify_access_token(token, verify_options:, scopes: nil, jwks_url: nil, remote_verify: nil, resource_metadata_mappings: nil)` and
    `protected_resource_metadata(overrides = {}, authorization_server: nil, oauth_provider_options: nil, external_scopes: [])`.
  - Local JWT verification should use the existing JWT plugin/JWKS behavior
    where available; remote verification should call `/oauth2/introspect` with
    confidential client credentials when configured. If implementing remote HTTP
    calls requires a new dependency, STOP and ask; otherwise use Ruby stdlib
    `Net::HTTP`.
  - The protected-resource metadata helper must reject `openid` scopes and
    unknown scopes unless they are listed in `external_scopes`.
  - Do not reintroduce `/mcp/*` routes. Upstream migration docs say MCP moved to
    `/oauth2/*`; `/mcp/get-session` is removed in favor of introspection.
- Schema:
  - OAuth Provider schema remains self-contained with `oauthClient`,
    `oauthRefreshToken`, `oauthAccessToken`, and `oauthConsent`.
  - Do not register legacy `oauthApplication` or core OIDC provider tables.
  - Ensure SQL schema generation and adapter smoke tests include indexes/FKs for
    hot lookup fields.

**Verify after implementation**:
`cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test`
Expected: exit 0.

### Step 4: Update OAuth Provider tests for the new canonical surface

Add or move tests under `packages/better_auth-oauth-provider/test/better_auth/oauth_provider/`.
Use existing files when the topic matches; otherwise create focused files.

Required test coverage:

- `unified_surface_test.rb`: requiring `better_auth/oauth_provider` defines
  `BetterAuth::Plugins.oauth_provider`, does not require separate
  `oidc_provider` or `mcp`, and the plugin id is `"oauth-provider"`.
- `metadata_test.rb`: OIDC metadata covers UserInfo, id token signing algs,
  end-session endpoint, advertised metadata, pairwise subject types, JWKS, and
  cache headers.
- `client_management_test.rb` or existing `oauth_client/endpoints_test.rb`:
  trusted clients are immutable through update/delete/rotate; dynamic
  registration can set `client_secret_expires_at`; public clients use
  `token_endpoint_auth_method: "none"`.
- `token_test.rb` / `token_pkce_test.rb`: custom token generators,
  `format_refresh_token` encrypt/decrypt, refresh rotation, custom claims,
  pinned field protection, disable JWT plugin behavior, client credentials.
- `mcp_test.rb`: MCP challenge header behavior, resource metadata URL mapping,
  `protected_resource_metadata`, rejection of `openid`, external scopes, local
  JWT verification, and remote introspection verification if implemented.
- Migration regression: no `/mcp/*` route and no core
  `BetterAuth::Plugins.mcp`/`oidc_provider` entrypoints are required to access
  OAuth Provider features.

**Verify**:
`cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test`
Expected: all OAuth Provider tests pass, including the new tests.

### Step 5: Update package docs and public repository docs

1. Rewrite `packages/better_auth-oauth-provider/README.md`:
   - Title: OAuth 2.1 Provider.
   - State that this gem is the canonical Ruby provider surface for OAuth 2.1,
     OIDC compatibility, and MCP/resource-server helpers.
   - Remove the line that says OIDC provider remains a core plugin.
   - Remove the line that says MCP/resource helpers are future work.
   - Document Ruby option names and mention camelCase aliases only where code
     supports them.
   - Include migration notes from removed `BetterAuth::Plugins.oidc_provider`
     and `BetterAuth::Plugins.mcp`.
2. Update root `README.md` package list to describe
   `better_auth-oauth-provider` as OAuth 2.1/OIDC/MCP provider support. Do not
   describe `better_auth-oidc` as a provider package; if it remains listed,
   label it as SSO/OIDC relying-party helpers.
3. Update `Gemfile` and `Rakefile` only if the separate provider package entries
   are no longer valid. Keep `better_auth-oidc` if SSO still depends on it.

**Verify**:
`rg -n "OIDC provider remains|future API-boundary|BetterAuth::Plugins\\.oidc_provider|BetterAuth::Plugins\\.mcp|/mcp/get-session|/mcp/register|/mcp/authorize|/mcp/token" README.md packages/better_auth-oauth-provider packages/better_auth docs-site/content/docs/plugins`
Expected: no matches except explicit migration text saying those old names are removed and users must use `oauth_provider`.

### Step 6: Replace docs-site OAuth Provider content and navigation

Honor `docs-site/AGENTS.md`: Ruby examples only, use `<UnderDevelopment />` for
anything intentionally incomplete, and keep docs under `docs-site/content/docs/`.

1. Replace `docs-site/content/docs/plugins/oauth-provider.mdx` with a Ruby
   version of the full upstream OAuth Provider docs:
   - Installation (`gem "better_auth-oauth-provider"`,
     `require "better_auth/oauth_provider"`, `BetterAuth::Plugins.oauth_provider`).
   - Key features: OAuth 2.1, OIDC compatibility, MCP/resource-server support,
     dynamic client registration, JWT/JWKS, prompts, introspection/revocation,
     grants.
   - Endpoint reference for all OAuth client, consent, register, authorize,
     token, continue, introspect, revoke, end-session, userinfo, and well-known
     endpoints.
   - API/resource-server verification with Ruby examples for local JWT
     verification, introspection, protected-resource metadata, and MCP handler.
   - Configuration sections for redirect screens, trusted clients, valid
     audiences, scopes, claims, expirations, registration, PKCE, organizations,
     client CRUD privileges, storage, rate limiting, refresh token formatting,
     advertised metadata, disabling JWT plugin, pairwise subject identifiers,
     MCP, schema, prefixes, optimizations, and migrations from OIDC/MCP.
2. Remove `docs-site/content/docs/plugins/oidc-provider.mdx`, or replace it with
   a short migration page that has no installation snippet and links to
   `/docs/plugins/oauth-provider`. If Fumadocs cannot tolerate a removed page
   during this change, keep the migration page but remove it from navigation.
3. Update `docs-site/content/docs/plugins/index.mdx`:
   - Remove OIDC Provider from core plugins.
   - Move MCP from "upstream-only removed" language to "included in OAuth
     Provider" wording.
   - Describe OAuth Provider as external gem support for OAuth 2.1/OIDC/MCP.
4. Update `docs-site/content/docs/plugins/meta.json`: remove `"oidc-provider"`
   from `pages`.
5. Update `docs-site/lib/plugins.ts`: remove the `"oidc-provider"` entry or mark
   it as removed if code requires historical metadata. Prefer removal.
6. Search `docs-site/components/sidebar-content.tsx` for hard-coded OAuth/OIDC
   plugin navigation. Remove OIDC Provider links and keep OAuth Provider.

**Verify**:
`cd docs-site && pnpm lint`
Expected: TypeScript check exits 0.

Then:
`cd docs-site && pnpm build`
Expected: production build exits 0 and has no broken MDX imports/routes.

### Step 7: Run final verification and clean up removed references

Run these commands in order:

1. `rg -n "BetterAuth::Plugins\\.(oidc_provider|mcp)|plugins/oidc_provider|plugins/mcp|OIDC Provider\\]|\\boidc-provider\\b|\\bmcp\\(" packages docs-site README.md Gemfile Rakefile`
   - Expected: no live support references. Acceptable matches are SSO
     relying-party wording, migration notes saying old provider plugins were
     removed, or lowercase "mcp" in OAuth Provider docs/helpers.
2. `cd packages/better_auth && BUNDLE_GEMFILE=Gemfile bundle exec rake ci`
   - Expected: exit 0.
3. `cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test`
   - Expected: exit 0.
4. `bundle exec standardrb`
   - Expected: exit 0.
5. `cd docs-site && pnpm lint`
   - Expected: exit 0.
6. `bundle exec rake ci`
   - Expected: exit 0.

If workspace CI is too slow locally, at minimum complete the package-level
commands and document why full workspace CI was not run.

## Test plan

- New/updated core tests prove `oidc_provider` and `mcp` are no longer supported
  public plugin factories.
- OAuth Provider package tests prove all provider behavior comes from
  `BetterAuth::Plugins.oauth_provider`.
- OAuth Provider tests cover upstream docs sections: metadata, client CRUD,
  dynamic registration, PKCE, token grants, refresh rotation, introspection,
  revocation, userinfo, end-session, pairwise, advertised metadata, resource
  verification, MCP challenge behavior, and schema.
- Docs build proves navigation no longer exposes standalone OIDC Provider and
  OAuth Provider docs render.

Use these existing tests as patterns:

- `packages/better_auth-oauth-provider/test/better_auth/oauth_provider/metadata_test.rb`
- `packages/better_auth-oauth-provider/test/better_auth/oauth_provider/token_pkce_test.rb`
- `packages/better_auth-oauth-provider/test/better_auth/oauth_provider/oauth_client/endpoints_test.rb`
- `packages/better_auth-oauth-provider/test/better_auth/oauth_provider/mcp_test.rb`
- `packages/better_auth/test/better_auth/plugins/external_plugin_shim_test.rb`

## Done criteria

All must hold:

- [ ] `BetterAuth::Plugins.oauth_provider` is the only supported provider plugin
      factory for OAuth/OIDC/MCP provider behavior.
- [ ] `BetterAuth::Plugins.oidc_provider` and `BetterAuth::Plugins.mcp` are not
      documented, not listed by the plugin loader, and not required for any
      provider feature.
- [ ] OAuth Provider tests pass and include MCP/resource-server helper coverage.
- [ ] Core tests pass after deleting/updating standalone OIDC Provider and MCP
      tests.
- [ ] Docs-site navigation has no standalone OIDC Provider page.
- [ ] `docs-site/content/docs/plugins/oauth-provider.mdx` covers the upstream
      OAuth Provider docs surface with Ruby examples.
- [ ] `rg -n "BetterAuth::Plugins\\.(oidc_provider|mcp)" packages docs-site README.md`
      returns no live usage examples.
- [ ] `cd packages/better_auth && BUNDLE_GEMFILE=Gemfile bundle exec rake ci`
      exits 0.
- [ ] `cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test`
      exits 0.
- [ ] `bundle exec standardrb` exits 0.
- [ ] `cd docs-site && pnpm lint` exits 0.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report back if:

- `packages/better_auth-oidc` turns out to be used as an OAuth/OIDC provider
  package rather than only SSO relying-party helpers; this plan intentionally
  excludes SSO package deletion.
- Removing core `mcp` or `oidc_provider` requires unrelated adapter/framework
  rewrites outside the in-scope files.
- Implementing resource-client remote verification requires a new gem.
- Upstream `reference/upstream-src/1.6.9/repository/packages/oauth-provider`
  is missing; run `./scripts/fetch-upstream-better-auth.sh` only after operator
  confirmation because this plan should not commit fetched sources.
- Docs-site build fails because of pre-existing unrelated docs-site changes in
  the dirty working tree. Capture the failing files and ask whether to continue.

## Maintenance notes

- Future provider work should land in `packages/better_auth-oauth-provider`,
  not core `packages/better_auth`, except for the external shim and shared
  protocol helpers.
- SSO OIDC is a relying-party feature and should stay separate from OAuth
  Provider. Review PRs carefully for confusion between "OIDC provider" and
  "OIDC SSO provider".
- The removed core `mcp` plugin had legacy `/mcp/*` routes. Do not resurrect
  them unless a separate migration-compatibility plan explicitly scopes that.
- The docs URL may change over time. At review, re-open
  https://better-auth.com/docs/plugins/oauth-provider and compare headings
  against the Ruby docs before merging.
