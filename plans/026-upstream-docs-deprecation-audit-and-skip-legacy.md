# Plan 026: Upstream Docs Deprecation Audit & Skip-Legacy Verification

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` unless a reviewer told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat ab6a2f3..HEAD -- reference/upstream-better-auth/VERSION.md plans/026-upstream-docs-deprecation-audit-and-skip-legacy.md docs-site/content/docs/plugins packages/better_auth/lib/better_auth/plugins packages/better_auth-oauth-provider`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: none (feeds into `plans/019-oauth-provider-unified-parity.md`, `plans/020-docs-parity-foundation.md`, and `plans/022-docs-plugins-parity.md`)
- **Category**: migration
- **Planned at**: commit `ab6a2f3`, 2026-06-16

## Why this matters

Upstream Better Auth v1.6.9 documents **178 MDX pages**. Several pages explicitly
mark APIs as deprecated, unstable, or superseded — especially the move from
**OIDC Provider** and **MCP** plugins to the unified **OAuth 2.1 Provider**
(`@better-auth/oauth-provider`). The Ruby port currently still ships separate
`BetterAuth::Plugins.oidc_provider` and `BetterAuth::Plugins.mcp` surfaces,
documents MCP as supported in `docs-site/content/docs/plugins/mcp.mdx`, and
still exposes legacy endpoints (for example `/forget-password/email-otp`,
`/mcp/*` aliases, `get_consent_html` on OIDC).

This plan produces a **machine-checkable inventory and verification matrix**
so maintainers can (a) confirm upstream docs are the correct revision, (b)
audit every page once, and (c) deliberately **skip legacy APIs** while
implementing/documenting the **new canonical APIs**, even when that implies
breaking changes for early Ruby adopters.

Breaking changes are an explicit goal for provider plugins: after verification,
implementation work belongs in Plan 019; docs exclusion work belongs in Plans
020–022.

## Current state

### Upstream pin and clone health

- Parity target: Better Auth **v1.6.9**, commit **`f484269228b7eb8df0e2325e7d264bb8d7796311`**
  per `reference/upstream-better-auth/VERSION.md`.
- Upstream docs path:
  `reference/upstream-src/1.6.9/repository/docs/content/docs/` (**178 MDX files**).
- Fetch script: `./scripts/fetch-upstream-better-auth.sh` clones tag `v1.6.9` only
  when the directory is empty; it does **not** refresh an existing clone.
- **Drift detected at plan time**: local clone HEAD is **`ab6a2f3`**
  (`openauth-oidc-v0.10.0-29-gab6a2f3`), **not** pinned commit `f484269`.
  `package.json` still reports `1.6.9`, but docs/content may differ from the
  official tag snapshot. npm `latest` is **1.6.19** (2026-06-16 check) — out of
  scope for parity, but note for future bump reviews.

### Canonical upstream deprecation signals (verified excerpts)

**MCP → OAuth Provider**

```8:16:reference/upstream-src/1.6.9/repository/docs/content/docs/plugins/mcp.mdx
<Callout type="warn">
  This plugin will soon be deprecated in favor of the [OAuth Provider Plugin](/docs/plugins/oauth-provider).
</Callout>
...
<Callout type="warn">
  This plugin is based on OIDC Provider plugin. It'll be moved to the OAuth Provider Plugin in the future.
</Callout>
```

**OIDC Provider → OAuth Provider**

```6:8:reference/upstream-src/1.6.9/repository/docs/content/docs/plugins/oidc-provider.mdx
<Callout type="warn">
  This plugin will soon be deprecated in favor of the [OAuth Provider Plugin](/docs/plugins/oauth-provider).
</Callout>
```

**MCP endpoint migration (OAuth 2 paths)**

```2135:2145:reference/upstream-src/1.6.9/repository/docs/content/docs/plugins/oauth-provider.mdx
### From MCP Plugin
...
The MCP endpoints moved from `/mcp` to the `/oauth2` equivalent.
* `/oauth2/authorize` (previously `/mcp/authorize`)
* `/oauth2/token` (previously `/mcp/token`)
* `/oauth2/register` (previously `/mcp/register`)
* `/mcp/get-session` removed as not OAuth 2 compliant, use `/oauth2/introspect` instead
```

**OIDC → OAuth Provider config breaking changes**

```2051:2062:reference/upstream-src/1.6.9/repository/docs/content/docs/plugins/oauth-provider.mdx
* **`idTokenExpiresIn`** now defaults to `10 hours` (previously `1 hour` through `accessTokenExpiresIn`)
* **`refreshTokenExpiresIn`** now defaults to `30 days` (previously `7 days`)
* **`consentPage`** is now required
* **`getConsentHTML`** is removed in favor of the `consentPage`
* **`requirePKCE`** (global option) is removed. PKCE is now required by default per OAuth 2.1.
* **`allowPlainCodeChallengeMethod`** is removed
* **`storeClientSecret`** now defaults to `hashed`
* JWT plugin now is enabled by default. To disable the plugin, set `disableJwtPlugin: true`.
```

**Other plugin deprecations in upstream docs**

| Area | Legacy | Canonical replacement | Evidence |
| --- | --- | --- | --- |
| Email OTP | `POST /forget-password/email-otp` | `POST /email-otp/request-password-reset` | `plugins/email-otp.mdx:198-200` |
| Admin | `allowImpersonatingAdmins` | `impersonate-admins` permission on roles | `plugins/admin.mdx:396-398` |
| Organization | `organizationCreation` hooks | `organizationHooks` | `plugins/organization.mdx:157,213-216` |
| API Key | response field `userId` | `referenceId` | `plugins/api-key/reference.mdx:581-595` |
| OAuth Provider | `allowUnauthenticatedClientRegistration` | future MCP DCR standard TBD | `plugins/oauth-provider.mdx:423-425` |
| Core secrets | bare `secret` option | versioned `secrets` + legacy decrypt fallback | `reference/options.mdx:211`, `reference/security.mdx:16` |

**Stability warnings (do not treat as production parity targets)**

| Plugin/page | Signal | Evidence |
| --- | --- | --- |
| OIDC Provider | "in active development … may not be suitable for production" | `plugins/oidc-provider.mdx:24-26` |
| Agent Auth | "not yet stable and may change" | `plugins/agent-auth.mdx:8-10` |
| Instrumentation | experimental OpenTelemetry | `reference/instrumentation.mdx:6-8` |
| Database joins | `experimentalJoins` default false | `concepts/database.mdx:994-1010` |
| Test Utils | test-only privileged helpers | `plugins/test-utils.mdx:8-10` |

### Ruby port gaps vs skip-legacy intent (verified)

- `packages/better_auth/lib/better_auth/plugins/oidc_provider.rb:8-9` — warns
  deprecation but still registers live `"oidc-provider"` plugin with
  `get_consent_html` support (`:291`).
- `packages/better_auth/lib/better_auth/plugins/mcp.rb:32-50` — live `"mcp"`
  plugin with legacy `/mcp/*` aliases via `mcp/legacy_aliases.rb:8-37`.
- `packages/better_auth/lib/better_auth/plugins/email_otp.rb:456-458` — still
  registers `/forget-password/email-otp`.
- `packages/better_auth/lib/better_auth/plugins/admin.rb:415` — still reads
  `allow_impersonating_admins`.
- `docs-site/content/docs/plugins/mcp.mdx:25` — documents
  `BetterAuth::Plugins.mcp` as supported (conflicts with `plans/README.md`
  exclusion policy).
- `docs-site/content/docs/plugins/oauth-provider.mdx` — stub (~194 lines vs
  upstream ~2146); missing migration sections.
- No `docs-site/content/docs/plugins/oidc-provider.mdx` (good — do not add).
- Plan 019 already specifies removing OIDC/MCP as separate supported surfaces.

### Repo conventions for deliverables

- Put generated inventories under `plans/artifacts/` (create directory).
- Do **not** commit `reference/upstream-src/**` changes.
- Match existing plan index style in `plans/README.md`.
- Verification commands from root: `bundle exec rake test`, `bundle exec rake ci`,
  `bundle exec standardrb`; docs: `cd docs-site && pnpm lint && pnpm build`.

## Commands you will need

| Purpose | Command | Expected on success |
| --- | --- | --- |
| Upstream commit check | `git -C reference/upstream-src/1.6.9/repository rev-parse HEAD` | equals `f484269228b7eb8df0e2325e7d264bb8d7796311` |
| Doc page count | `find reference/upstream-src/1.6.9/repository/docs/content/docs -name '*.mdx' \| wc -l` | `178` |
| Deprecation scan | `rg -i 'deprecat\|will soon be\|legacy\|removed in favor\|breaking change' reference/upstream-src/1.6.9/repository/docs/content/docs` | review output; save to artifact |
| Ruby legacy scan | `rg -n 'forget-password/email-otp\|allow_impersonating_admins\|get_consent_html\|legacy_mcp\|/mcp/' packages/` | list hits for matrix |
| Core tests | `bundle exec rake test` | exit 0 |
| Docs build | `cd docs-site && pnpm lint && pnpm build` | exit 0 |

## Scope

**In scope**

- Refresh or validate upstream clone at pinned commit (read-only except deleting
  and re-cloning ignored upstream tree when operator approves).
- Generate full upstream page inventory (178 pages) with classification columns.
- Generate deprecation/migration verification matrix (docs + upstream TS `@deprecated`).
- Cross-check Ruby code and Ruby docs against matrix; file gaps as checklist rows.
- Update `plans/README.md` status and link artifacts.
- Recommend execution order vs Plans 019–025 (no code changes in this plan).

**Out of scope**

- Implementing removals or API changes (Plan 019 and follow-ups).
- Copy-first docs port of full upstream prose (Plans 020–025).
- Bumping parity target from v1.6.9 to npm latest 1.6.19.
- Porting Agent Auth, Test Utils, Infrastructure, JS integrations, or unported
  payment plugins.

## Git workflow

- Branch: `advisor/026-upstream-deprecation-audit`
- Commit artifacts under `plans/artifacts/` and matrix updates under `plans/`.
- Message style (from repo history): `docs(plans): add upstream deprecation audit matrix`
- Do NOT push or open a PR unless the operator instructs it.

## Steps

### Step 1: Reconcile upstream docs source to pinned commit

The audit is invalid if the clone is not at `f484269`.

1. Record current HEAD:
   ```bash
   git -C reference/upstream-src/1.6.9/repository rev-parse HEAD
   git -C reference/upstream-src/1.6.9/repository log -1 --oneline
   ```
2. If HEAD ≠ `f484269228b7eb8df0e2325e7d264bb8d7796311`, **STOP** and ask the
   operator to approve re-clone (destructive to ignored tree only):
   ```bash
   rm -rf reference/upstream-src/1.6.9/repository
   ./scripts/fetch-upstream-better-auth.sh
   git -C reference/upstream-src/1.6.9/repository rev-parse HEAD
   ```
3. Record upstream doc count and top-level sections:
   ```bash
   find reference/upstream-src/1.6.9/repository/docs/content/docs -name '*.mdx' | wc -l
   ls reference/upstream-src/1.6.9/repository/docs/content/docs
   ```

**Verify**: HEAD equals `f484269…` and MDX count is `178`.

### Step 2: Generate full upstream page inventory

Create `plans/artifacts/026-upstream-page-inventory.tsv` with one row per MDX
file. Columns:

```
path	section	title	ruby_action	ruby_doc_status	notes
```

Rules for `ruby_action`:

| Action | When |
| --- | --- |
| `PORT` | Supported Ruby feature; copy-first docs target (Plans 021–025) |
| `PORT_SERVER_ONLY` | Server routes/options portable; strip `createAuthClient` sections |
| `SKIP_JS_ONLY` | integrations/, examples/, concepts/client.mdx, concepts/typescript.mdx |
| `SKIP_PRODUCT` | infrastructure/** (hosted Better Auth product) |
| `SKIP_UNPORTED` | agent-auth, test-utils, payment plugins without Ruby gems (autumn, chargebee, creem, dodopayments, polar) except stripe |
| `SKIP_DEPRECATED` | oidc-provider, mcp plugin docs — reference only for migration matrix |
| `SKIP_AI_DOCS` | ai-resources/** except index if needed for CLI note |
| `MIGRATION_ONLY` | oidc-provider, mcp — do not PORT as supported pages |

Generate mechanically:

```bash
find reference/upstream-src/1.6.9/repository/docs/content/docs -name '*.mdx' -print \
  | sort \
  | while read -r f; do
      rel="${f#*docs/content/docs/}"
      section="${rel%%/*}"
      title="$(sed -n 's/^title: //p' "$f" | head -1)"
      echo -e "${rel}\t${section}\t${title}"
    done > plans/artifacts/026-upstream-page-inventory.raw.tsv
```

Then hand-fill `ruby_action`, `ruby_doc_status` (NONE | STUB | OK | WRONG),
and `notes` by comparing to `docs-site/content/docs/**` and
`plans/README.md` exclusion list.

**Verify**:

```bash
wc -l plans/artifacts/026-upstream-page-inventory.tsv
# expect 179 lines (178 data + header) or 178 if no header in wc
rg -c '^SKIP_DEPRECATED' plans/artifacts/026-upstream-page-inventory.tsv
# expect 2 (oidc-provider.mdx, mcp.mdx)
```

### Step 3: Build deprecation & migration verification matrix

Create `plans/artifacts/026-deprecation-verification-matrix.md` with sections
below. Each row must include: upstream evidence (`file:line`), Ruby code
evidence (path or `NONE`), required action, priority (P0/P1/P2), owner plan.

#### P0 — Provider consolidation (breaking OK)

| ID | Upstream canonical | Do NOT support in Ruby | Verify in Ruby |
| --- | --- | --- | --- |
| D-01 | `BetterAuth::Plugins.oauth_provider` only | `Plugins.oidc_provider`, `Plugins.mcp` as supported plugins | `plugin_loader.rb`, docs sidebar, OpenAPI |
| D-02 | `/oauth2/*` routes | `/mcp/register`, `/mcp/authorize`, `/mcp/token`, `/mcp/userinfo`, `/mcp/jwks` | `mcp/legacy_aliases.rb` |
| D-03 | `/oauth2/introspect` | `/mcp/get-session` | grep packages for get_mcp_session as public API |
| D-04 | `consent_page` required | `get_consent_html` | `oidc_provider.rb`, oauth-provider gem |
| D-05 | PKCE default S256; per-client `require_pkce: false` only | global `require_pkce` option | oauth-provider config |
| D-06 | `client_registration_default_scopes` (array) | MCP/OIDC `defaultScope` string | oauth-provider register |
| D-07 | `store_client_secret: "hashed"` default | plain client secrets by default | oauth-provider + schema |
| D-08 | Tables `oauthClient`, split refresh tokens | `oauthApplication`, monolithic access token table | oauth-provider schema/migrations |
| D-09 | JWT plugin on by default for oauth-provider | `disable_jwt_plugin: true` only when intentional | oauth-provider tests |

Cross-read upstream migration sections:

- `plugins/oauth-provider.mdx` — "Migrations" → "From OIDC Provider Plugin"
- `plugins/oauth-provider.mdx` — "From MCP Plugin"
- Upstream tests under `packages/oauth-provider/` and
  `packages/better-auth/src/plugins/oidc-provider/`

Also scan upstream TS deprecations:

```bash
rg -n '@deprecated|deprecate\(' \
  reference/upstream-src/1.6.9/repository/packages/better-auth/src/plugins \
  reference/upstream-src/1.6.9/repository/packages/oauth-provider/src \
  > plans/artifacts/026-upstream-ts-deprecations.txt
```

Map each hit to a matrix row.

**Verify**: matrix has ≥9 P0 rows and cites at least one `file:line` each.

#### P1 — Core/plugin legacy options

| ID | Canonical API | Legacy to drop from docs/new code |
| --- | --- | --- |
| D-10 | `/email-otp/request-password-reset` | `/forget-password/email-otp` |
| D-11 | Admin role permission `impersonate-admins` | `allow_impersonating_admins` |
| D-12 | `organization_hooks` | `organization_creation` hooks |
| D-13 | API key `referenceId` in responses/schema | `userId` field on apikey model responses |
| D-14 | Versioned `secrets` | documenting bare `secret` as primary |

For each ID, grep Ruby and record pass/fail:

```bash
rg -n 'forget-password/email-otp|allow_impersonating_admins|organization_creation|get_consent_html|userId.*apikey|/mcp/' packages/ docs-site/
```

**Verify**: every P1 row marked PASS (legacy absent) or FAIL with file:line.

#### P2 — Unstable / future deprecation (document gap, do not port legacy)

| ID | Item | Ruby action |
| --- | --- | --- |
| D-15 | `allowUnauthenticatedClientRegistration` | Implement now if needed for MCP DCR; mark unstable in docs |
| D-16 | Agent Auth plugin | Exclude until stable |
| D-17 | OAuth Provider gaps (introspection bearer, sector_identifier_uri, etc.) | Document `<UnderDevelopment />` not silent parity |
| D-18 | SSO deprecated SAML algorithms | Ensure `on_deprecated` warn/reject matches upstream |
| D-19 | `experimentalJoins` | Default off; mark experimental in Ruby docs |

**Verify**: each P2 row lists upstream `file:line` and Ruby status.

### Step 4: Audit Ruby docs-site against inventory

Compare `plans/artifacts/026-upstream-page-inventory.tsv` to
`docs-site/content/docs/**`:

1. List docs pages that should **not** exist as supported:
   ```bash
   test ! -f docs-site/content/docs/plugins/oidc-provider.mdx
   # mcp.mdx SHOULD NOT be supported — flag if present without deprecation banner
   ```
2. For each `SKIP_*` upstream page, confirm no sidebar link in
   `docs-site/components/sidebar-content.tsx` and `docs-site/lib/plugins.ts`.
3. For each `PORT` page with `ruby_doc_status=STUB`, record upstream line count
   vs local (reuse methodology from Plan 020):
   ```bash
   wc -l docs-site/content/docs/plugins/oauth-provider.mdx \
         reference/upstream-src/1.6.9/repository/docs/content/docs/plugins/oauth-provider.mdx
   ```
4. Append findings to `plans/artifacts/026-docs-gap-report.md`.

**Verify**: gap report lists every plugin page where local lines < 50% upstream
AND `ruby_action=PORT`.

### Step 5: Write maintainer decision checklist (deliverable)

Append to `plans/artifacts/026-deprecation-verification-matrix.md` a section
**"Maintainer sign-off checklist"** — copy verbatim for human review:

```markdown
## Maintainer sign-off checklist

### Provider (breaking changes approved)
- [ ] Remove `BetterAuth::Plugins.mcp` and `BetterAuth::Plugins.oidc_provider` from public docs and plugin loader (Plan 019)
- [ ] Remove `/mcp/*` legacy routes from codebase (Plan 019)
- [ ] Expand oauth-provider docs from upstream oauth-provider.mdx including migration sections (Plans 022/019)
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
```

**Verify**: file exists and checklist has all boxes unchecked (for maintainer).

### Step 6: Wire dependency order and update plan index

Edit `plans/README.md`:

1. Add row for Plan 026 (status TODO).
2. Under "Dependency notes", add:
   - **026** should complete before **019** implementation starts (or in parallel
     with 019 Step 1 only) so P0/P1 matrix is the acceptance checklist for 019.
   - **026** inventory feeds **020–022** exclusion rules and page lists.
   - **019** remains the implementation plan for breaking provider consolidation.

**Verify**:

```bash
rg '026' plans/README.md
```

## Test plan

This plan is audit-only. No new Minitest/RSpec tests.

Optional sanity after operator runs Plan 019 later:

- `bundle exec rake test` — all pass after legacy removals.
- Grep gates from Done criteria — zero matches for removed legacy paths.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] Upstream clone HEAD equals `f484269228b7eb8df0e2325e7d264bb8d7796311`
- [ ] `plans/artifacts/026-upstream-page-inventory.tsv` exists with 178 upstream pages classified
- [ ] `plans/artifacts/026-deprecation-verification-matrix.md` exists with P0/P1/P2 tables and maintainer checklist
- [ ] `plans/artifacts/026-upstream-ts-deprecations.txt` exists
- [ ] `plans/artifacts/026-docs-gap-report.md` exists
- [ ] Matrix documents explicit FAIL rows for: `mcp.rb` legacy routes, `email_otp.rb` legacy route, `docs-site/.../mcp.mdx` supported doc
- [ ] `plans/README.md` lists Plan 026 with dependency notes
- [ ] No files outside `plans/` modified

## STOP conditions

Stop and report back (do not improvise) if:

- Operator declines re-cloning upstream and HEAD ≠ `f484269` (audit would be
  against wrong revision — report exact HEAD and `git log -1`).
- Upstream MDX count ≠ 178 at pinned commit (upstream layout changed — revise
  inventory approach).
- A deprecation callout cited in this plan is absent at pinned commit (docs
  changed between drifted clone and tag — re-read and revise matrix).
- You discover Ruby already removed all P0 legacy surfaces (matrix all PASS) —
  report and skip to docs-only gaps; do not re-implement.

## Maintenance notes

- Re-run Step 1–3 when bumping `reference/upstream-better-auth/VERSION.md`.
- When npm `latest` advances beyond v1.6.9, diff deprecation keywords between
  old and new tag before porting docs:
  `git diff v1.6.9..v1.6.19 -- docs/content/docs/plugins/oauth-provider.mdx` (after fetching both tags locally).
- Plan 019 executor should use P0 rows as acceptance tests; Plan 022 should use
  `SKIP_DEPRECATED` pages only for migration callouts inside oauth-provider docs,
  not standalone plugin pages.
- Reviewers should reject PRs that add supported docs for `oidc-provider`, `mcp`,
  or `agent-auth` without explicit maintainer override.
