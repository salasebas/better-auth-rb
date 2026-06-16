# Plan 020: Docs Parity Foundation (Upstream v1.6.9 → RubyAuth)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan in
> `plans/README.md` unless a reviewer tells you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 0d19370..HEAD -- docs-site/scripts docs-site/content/docs docs-site/AGENTS.md docs-site/components/docs`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: docs
- **Planned at**: commit `0d19370`, 2026-06-15

## Why this matters

RubyAuth's docs site has ~130 MDX pages but most plugin and concept pages are
38-line stubs that say "see plugin tests." Upstream Better Auth v1.6.9 has
~178 pages with full API reference, configuration tables, and examples. Users
cannot adopt plugins or adapters without parity docs adapted to Ruby.

This plan creates the repeatable pipeline (upstream fetch, page inventory,
mechanical transforms, Ruby example rules) that plans 021–025 execute against.
Without it, each page will be ported inconsistently and client-only TypeScript
sections will leak into Ruby docs.

## Current state

- Docs live in `docs-site/content/docs/` (Fumadocs MDX).
- Sidebar is hand-maintained in `docs-site/components/sidebar-content.tsx`
  (not driven solely by `meta.json`).
- Upstream parity target is v1.6.9 per `reference/upstream-better-auth/VERSION.md`.
- Upstream docs path inside the monorepo clone:
  `docs/content/docs/` (tag `v1.6.9`, commit `f484269`).
- Existing sync helper `docs-site/scripts/sync-beta-content.ts` clones the
  **`next`** branch into `content/docs-beta` and is **disabled by default**
  (`BETA_DOCS_SKIP` unset). Do not use it for parity work — use v1.6.9.
- Good Ruby-first exemplars already exist:
  - `docs-site/content/docs/installation.mdx` (~255 lines, Rails/Rack tabs)
  - `docs-site/content/docs/adapters/postgresql.mdx`
  - `docs-site/content/docs/authentication/github.mdx`
- Stub pattern to replace (32 plugin pages, ~38 lines each):

```mdx
# docs-site/content/docs/plugins/2fa.mdx (representative stub)
## Installation
```ruby
BetterAuth.auth(... plugins: [BetterAuth::Plugins.two_factor(...)] )
```
## Usage
See the plugin tests under `packages/better_auth/test/better_auth/plugins/`
```

- Inventory vs upstream v1.6.9 (automated line-count compare):
  - **OK**: 72 pages (mostly auth providers, error stubs, integrations)
  - **STUB**: 32 pages (<50 lines, upstream >100) — almost all plugins
  - **THIN**: 18 pages (<33% upstream lines) — concepts, basic-usage, options
  - **MISSING**: 56 upstream pages not present locally

- MDX components available (`docs-site/components/docs/mdx-components.tsx`):
  `APIMethod`, `GenerateSecret`, `DatabaseSchema`, `RubyAuthDisclaimer`, etc.
- `<UnderDevelopment>` for features not yet at parity
  (`docs-site/components/docs/under-development.tsx`).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Fetch upstream source | `./scripts/fetch-upstream-better-auth.sh` | `reference/upstream-src/1.6.9/repository/` exists |
| Docs typecheck | `cd docs-site && pnpm lint` | exit 0 |
| Docs build | `cd docs-site && pnpm build` | exit 0 |
| Remark lint (optional) | `cd docs-site && pnpm exec remark content/docs --frail` | exit 0 if configured |

## Scope

**In scope**:
- `docs-site/scripts/port-upstream-doc.mjs` (create)
- `docs-site/scripts/docs-parity-manifest.json` (create)
- `docs-site/scripts/docs-parity-rules.md` (create — transform cookbook)
- `docs-site/AGENTS.md` (append parity workflow section)

**Out of scope**:
- Editing individual MDX content pages (plans 021–024)
- Ruby gem implementation changes
- `reference/upstream-src/**` commits
- `content/docs-beta/**`

## Git workflow

- Branch: `docs/020-parity-foundation`
- Commit message style: `docs(site): add upstream parity port tooling`
- Do NOT push or open a PR unless the operator instructs it.

## Steps

### Step 1: Ensure upstream v1.6.9 clone exists locally

Run from repo root:

```bash
./scripts/fetch-upstream-better-auth.sh
test -d reference/upstream-src/1.6.9/repository/docs/content/docs
```

**Verify**: `find reference/upstream-src/1.6.9/repository/docs/content/docs -name '*.mdx' | wc -l` → approximately `178`.

### Step 2: Create the parity manifest

Create `docs-site/scripts/docs-parity-manifest.json` listing every upstream
page with fields:

```json
{
  "upstream_tag": "v1.6.9",
  "pages": [
    {
      "slug": "plugins/2fa.mdx",
      "action": "port",
      "ruby_source": "packages/better_auth/test/better_auth/plugins/two_factor_test.rb",
      "ruby_plugin": "BetterAuth::Plugins.two_factor",
      "gem": "better_auth"
    }
  ]
}
```

Populate using this classification:

| `action` | Meaning |
|----------|---------|
| `port` | Copy upstream prose/structure, Ruby-ify examples (plans 021–024) |
| `skip_client` | Do not create — client-only (see exclusion list below) |
| `skip_upstream_product` | Do not create — Better Auth hosted infra / TS-only ORMs |
| `skip_unported` | Stub page saying "not yet ported" OR omit from sidebar |
| `keep_local` | Ruby-only page; do not overwrite (integrations/*) |
| `merge_local` | Port upstream but preserve Ruby integration sections |

**Exclusion list (`skip_client`)** — never port:
- `concepts/client.mdx`
- `concepts/typescript.mdx`
- `examples/*.mdx` (JS framework demos)
- `integrations/astro|convex|electron|elysia|encore|expo|express|fastify|hono|lynx|nestjs|next|nitro|nuxt|react-router|solid-start|svelte-kit|tanstack|waku.mdx`
- Any `<Step>` titled "Add the client plugin" or sections mentioning
  `createAuthClient`, `authClient`, `better-auth/client`, `*Client()` plugins

**Exclusion list (`skip_upstream_product`)**:
- `infrastructure/**`
- `ai-resources/**` (optional: later Ruby LLM page — out of scope here)

**ORM / dialect pages (`merge_into_other_relational`)** — do NOT create separate
`adapters/drizzle.mdx` or `adapters/prisma.mdx`. Instead, when porting upstream
content from those files, append sections to
`adapters/other-relational-databases.mdx` under `## ORM integrations`:

- **Drizzle / Prisma (upstream)** → document as N/A in Ruby; explain that
  RubyAuth uses native SQL adapters or Rails ActiveRecord instead
- **ActiveRecord** → Rails path is documented (`better_auth-rails`); standalone
  ActiveRecord outside Rails: wrap in `<UnderDevelopment>` until confirmed
- **Sequel / ROM (Hanami)** → link to Hanami integration; `<UnderDevelopment>`
  for non-Hanami Sequel if not verified
- **Kysely community dialect list** (PlanetScale, Neon, D1, etc.) → port the
  upstream bullet list verbatim under `## Community dialects (upstream reference)`
  with a top-level `<UnderDevelopment>` noting RubyAuth does not ship these
  drivers — users need a custom adapter (link to `guides/create-a-db-adapter`)

**Exclusion list (`skip_unported`)** — no Ruby implementation at v1.6.9 parity:
- `plugins/agent-auth.mdx`
- `plugins/autumn.mdx`, `plugins/chargebee.mdx`, `plugins/creem.mdx`,
  `plugins/dodopayments.mdx`, `plugins/polar.mdx`
- `plugins/test-utils.mdx`

**`keep_local`** (9 pages — do not overwrite):
- `integrations/{rails,hanami,sinatra,roda,grape,rack}.mdx`
- `plugins/custom-session.mdx`
- `reference/errors/please_restart_the_process.mdx`

**External gem mapping** (use in manifest `gem` field):

| Plugin doc slug | Gem | Require path |
|-----------------|-----|--------------|
| `plugins/api-key/*` | `better_auth-api-key` | `better_auth/api_key` |
| `plugins/passkey.mdx` | `better_auth-passkey` | `better_auth/passkey` |
| `plugins/sso.mdx` | `better_auth-sso` | `better_auth/sso` |
| `plugins/scim.mdx` | `better_auth-scim` | `better_auth/scim` |
| `plugins/stripe.mdx` | `better_auth-stripe` | `better_auth/stripe` |
| `plugins/oauth-provider.mdx` | `better_auth-oauth-provider` | `better_auth/oauth_provider` |
| `plugins/mcp.mdx` | `better_auth` (core) | `better_auth/plugins/mcp` |
| `plugins/i18n.mdx` | `better_auth` (core) | depends on plan 019 |

**Verify**: `node -e "JSON.parse(require('fs').readFileSync('docs-site/scripts/docs-parity-manifest.json'))"` → exit 0; manifest has an entry for every upstream `.mdx` slug.

### Step 3: Create transform rules document

Create `docs-site/scripts/docs-parity-rules.md` with these mandatory rules:

#### 3a. Copy-first workflow (mandatory — do NOT rewrite from scratch)

**The default mistake to avoid:** rewriting pages as short Ruby summaries. Current
local adapter pages are ~50–70 lines; upstream is ~100–190+ with joins, schema
tables, and troubleshooting. The executor must **preserve upstream prose, headings,
tables, callouts, and section order** unless the section is client-only.

For each `port` page:

1. **Copy verbatim** upstream file:
   `reference/upstream-src/1.6.9/repository/docs/content/docs/<slug>`
   → `docs-site/content/docs/<slug>` (overwrite local content)
2. Run mechanical transforms (Step 3b) — product names, CLI commands, links
3. Replace **only** TypeScript/JavaScript code blocks with Ruby from tests
4. Delete client-only sections — do not delete server sections
5. Add `<RubyAuthDisclaimer />` after frontmatter where `installation.mdx` does
6. Add `<UnderDevelopment>` when Ruby lacks parity for a **specific upstream section**
   (programmatic migrations, a Kysely community dialect) — keep surrounding prose

**Line-count sanity check after port (before Ruby example pass):**

| Page kind | Expect after copy + client removal |
|-----------|-------------------------------------|
| Adapter (`adapters/postgresql.mdx`) | ≥ 80% of upstream line count |
| Concept (`concepts/database.mdx`) | ≥ 70% of upstream line count |
| Plugin stub replacement | ≥ 50% of upstream line count |

If local page is < 50% upstream lines after port, the executor rewrote instead of
copied — STOP and redo from upstream file.

#### 3b. Mechanical replacements

| Upstream pattern | RubyAuth replacement |
|------------------|---------------------|
| `betterAuth({` | `BetterAuth.auth(` |
| `import { betterAuth } from "better-auth"` | `require "better_auth"` |
| `import { admin } from "better-auth/plugins"` | `BetterAuth::Plugins.admin` |
| `admin()` | `BetterAuth::Plugins.admin` |
| `twoFactor()` | `BetterAuth::Plugins.two_factor(...)` |
| `npx auth migrate` / `npx auth@latest migrate` | `bundle exec better-auth migrate --cwd . --config config/better_auth.rb --yes` |
| `npx auth generate` / `npx auth@latest generate` | `bundle exec better-auth generate --cwd . --dialect postgres --output db/better_auth/schema.sql --config config/better_auth.rb` |
| `npm install better-auth` | `gem "better_auth"` + `bundle install` |
| Kysely / `pg` Pool / `mysql2/promise` examples | `BetterAuth::Adapters::Postgres` / `MySQL` / `SQLite` / `MSSQL` — see adapter tests |
| "supported via Kysely adapter" prose | Keep sentence structure; replace "Kysely" with "RubyAuth SQL adapters" and link to `/docs/adapters/other-relational-databases` |
| `drizzle-kit` / `@better-auth/drizzle-adapter` | Move to `/docs/adapters/other-relational-databases#orm-integrations` with `<UnderDevelopment>` — no standalone drizzle page |
| `@better-auth/prisma-adapter` / Prisma client | Same — ActiveRecord section under `#orm-integrations` |
| `process.env.BETTER_AUTH_SECRET` | `ENV.fetch("BETTER_AUTH_SECRET")` |
| `auth.api.signInEmail` | `auth.api.sign_in_email` |
| `authClient.signIn.email` | **DELETE section** — use HTTP `POST /api/auth/sign-in/email` |
| `[!code highlight]` comments | Remove entirely |
| ` ```ts` fences | ` ```ruby` after rewriting content |
| `Better Auth` (product name in prose) | `RubyAuth` where referring to this implementation; keep "Better Auth" when citing upstream design inspiration |

#### 3c. APIMethod blocks

Keep upstream `<APIMethod path="..." method="POST">` wrappers. Inside them,
replace TypeScript `type foo = { ... }` blocks with:

- Ruby `auth.api` example when the method exists on `auth.api` in tests
- Or a `curl`/HTTP example for browser-facing routes

Find API method names in tests:

```bash
rg 'auth\.api\.' packages/better_auth/test/better_auth/plugins/two_factor_test.rb
```

Match snake_case Ruby names to upstream camelCase paths using existing route
tests — do not invent endpoints.

#### 3d. Tabs

Replace framework tabs as follows:

| Upstream tabs | RubyAuth tabs |
|---------------|---------------|
| Next.js / Nuxt / Svelte | Rails / Plain Rack |
| `migrate` / `generate` | keep, with Ruby CLI commands |
| Prisma / Drizzle | **Remove tab** — link to ActiveRecord / native adapter docs |

#### 3e. Ruby example sources (priority order)

1. Plugin test file from manifest `ruby_source`
2. Adapter/integration spec under `packages/better_auth-*/spec` or `test`
3. `docs-site/content/docs/installation.mdx` patterns for config/migrations
4. If no test covers a documented option: mark option with
   `<UnderDevelopment>` and link to upstream issue — do not fabricate API

**Verify**: rules file exists and includes all tables above.

### Step 4: Create port helper script

Create `docs-site/scripts/port-upstream-doc.mjs`:

```javascript
#!/usr/bin/env node
/**
 * Usage: node docs-site/scripts/port-upstream-doc.mjs plugins/2fa.mdx
 * Copies upstream v1.6.9 MDX, applies mechanical transforms, writes to content/docs/.
 * Does NOT auto-generate Ruby examples — executor must edit code blocks after.
 */
```

Minimum behavior:

- Accept slug argument (`plugins/2fa.mdx`)
- Read from `../../reference/upstream-src/1.6.9/repository/docs/content/docs/<slug>`
- Apply regex transforms from `docs-parity-rules.md` (inline the core regexes in script)
- Strip lines matching client-plugin patterns (`createAuthClient`, `auth-client.ts`, `/client/plugins`)
- Remove `[!code highlight]` markers
- Write to `docs-site/content/docs/<slug>`
- Print diff stat and remind executor to replace code blocks

Make executable: `chmod +x docs-site/scripts/port-upstream-doc.mjs`

**Verify**:

```bash
node docs-site/scripts/port-upstream-doc.mjs plugins/2fa.mdx --dry-run 2>/dev/null || \
  node docs-site/scripts/port-upstream-doc.mjs plugins/2fa.mdx
wc -l docs-site/content/docs/plugins/2fa.mdx
```

→ line count should jump from ~38 to ~500+ (before Ruby example pass).

Revert the test port after verify if executing on a clean branch for tooling-only PR:

```bash
git checkout -- docs-site/content/docs/plugins/2fa.mdx
```

(or leave it if plan 022 will immediately follow).

### Step 5: Update AGENTS.md

Append to `docs-site/AGENTS.md`:

```markdown
## Upstream doc parity

- Source of truth: Better Auth v1.6.9 docs at
  `reference/upstream-src/1.6.9/repository/docs/content/docs/`.
- Workflow: `node docs-site/scripts/port-upstream-doc.mjs <slug>`, then replace
  code blocks using `docs-site/scripts/docs-parity-manifest.json` test paths.
- Never port client-only sections (`createAuthClient`, framework JS integrations).
- Verify with `cd docs-site && pnpm lint && pnpm build`.
```

**Verify**: `grep -q 'Upstream doc parity' docs-site/AGENTS.md`

## Test plan

No Ruby tests. Validation is tooling + manifest completeness:

- Manifest parses as JSON and covers all 178 upstream slugs
- Port script runs without error on `plugins/admin.mdx` and `concepts/database.mdx`
- `pnpm lint` still passes (no MDX committed broken)

## Done criteria

- [x] `docs-site/scripts/docs-parity-manifest.json` exists with classified entries for all upstream pages
- [x] `docs-site/scripts/docs-parity-rules.md` exists with transform tables
- [x] `docs-site/scripts/port-upstream-doc.mjs` runs on a sample slug
- [x] `docs-site/AGENTS.md` documents the workflow
- [x] `cd docs-site && pnpm lint` exits 0
- [x] `plans/README.md` status row for 020 updated

## STOP conditions

- `reference/upstream-src/1.6.9/repository/docs/content/docs/` missing after fetch — report; do not guess content from memory
- Upstream page count differs from ~178 by more than 10 — manifest may need advisor refresh
- Port script would overwrite a `keep_local` page — abort that slug
- Mechanical transforms break MDX frontmatter — fix script, do not hand-edit 100 files

## Maintenance notes

- When bumping upstream parity version in `VERSION.md`, regenerate manifest
  from new tag and re-run line-count diff
- Plan 019 (`plugins/i18n.mdx`) should land before or alongside plan 022 i18n doc
- Reviewers: ensure no `createAuthClient` or `npm install` strings remain in ported pages (plans 021–025 gate)
