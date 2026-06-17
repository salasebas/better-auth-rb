# Plan 023: Docs Parity — Adapters & Authentication Finish-Pass

> **Executor instructions**: Complete plan 020. For pages that still need work,
> **copy upstream verbatim first** and adapt examples only. Do not replace
> current long Ruby pages with shorter summaries. Run verification after each
> section.
>
> **Drift check (run first)**:
> `git diff --stat 2ce7a4a..HEAD -- docs-site/content/docs/adapters docs-site/content/docs/authentication docs-site/content/docs/concepts/database.mdx`

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/020-docs-parity-foundation.md
- **Category**: docs
- **Planned at**: commit `2ce7a4a`, 2026-06-16

## Why this matters

Adapters and most authentication provider pages have already been expanded.
This plan is now a finish-pass: verify that adapter/authentication pages follow
the literal upstream-copy rule, fix malformed examples and any client-only leaks,
and only copy upstream again where the page is still thin or missing a required
server-side section.

The user requirement remains strict: same upstream content, headings, tables,
and order; replace examples only, remove unsupported/client-only sections, and
fix bad formatting. Unclear Ruby support (ActiveRecord outside Rails, Kysely
community dialects, Drizzle/Prisma) goes in
`other-relational-databases.mdx` with `<UnderDevelopment>` — not omitted silently.

## Current state — upstream vs local (v1.6.9)

| Slug | Upstream lines | Local lines | Status |
|------|----------------|-------------|--------|
| `adapters/postgresql.mdx` | 189 | 197 | OK-ish — verify formatting/copy fidelity |
| `adapters/mysql.mdx` | 100 | 202 | OK-ish — verify formatting/copy fidelity |
| `adapters/sqlite.mdx` | 134 | 189 | OK-ish — verify Node/Bun driver sections removed |
| `adapters/mssql.mdx` | 131 | 177 | OK-ish — verify formatting/copy fidelity |
| `adapters/mongo.mdx` | 61 | 190 | OK-ish — verify current additions are Ruby-specific and accurate |
| `adapters/other-relational-databases.mdx` | 46 | missing locally | Create/merge if absent; absorb Drizzle/Prisma |
| `adapters/community-adapters.mdx` | upstream exists | missing locally | Create only if supported by navigation/manifest |
| `adapters/drizzle.mdx` | 179 | missing | Do not create; merge into other-relational |
| `adapters/prisma.mdx` | 96 | missing | Do not create; merge into other-relational |
| `concepts/database.mdx` | 1024 | 400 | Plan 021; adapter links must match |
| `authentication/email-password.mdx` | 533 | 166 | Plan 021 |

**Ruby adapter implementations** (for example replacement only):

| Upstream driver | Ruby replacement |
|-----------------|------------------|
| `pg` Pool | `BetterAuth::Adapters::Postgres` + `pg` gem |
| `mysql2/promise` | `BetterAuth::Adapters::MySQL` + `mysql2` gem |
| `better-sqlite3` / `node:sqlite` / `bun:sqlite` | `BetterAuth::Adapters::SQLite` + `sqlite3` gem (single section — delete Node/Bun subsections) |
| Kysely `MssqlDialect` + Tedious | `BetterAuth::Adapters::MSSQL` + Sequel/`tiny_tds` |
| `@better-auth/mongo-adapter` | `better_auth-mongodb` gem + `BetterAuth::Adapters::MongoDB` |
| Drizzle adapter | **N/A** — see ORM section in other-relational |
| Prisma adapter | **N/A** — Rails ActiveRecord via `better_auth-rails` |

**Joins in Ruby** (keep upstream section, replace config example):

```ruby
BetterAuth.auth(
  secret: ENV.fetch("BETTER_AUTH_SECRET"),
  base_url: ENV.fetch("BETTER_AUTH_URL"),
  database: :postgres,
  experimental: { joins: true }
)
```

## Commands

| Purpose | Command |
|---------|---------|
| Port when needed | `node docs-site/scripts/port-upstream-doc.mjs adapters/postgresql.mdx` |
| Line-count check | `wc -l docs-site/content/docs/adapters/*.mdx` |
| Adapter tests | `rg 'Postgres|MySQL|SQLite|MSSQL' packages/better_auth/test/better_auth/adapters/` |
| Verify | `cd docs-site && pnpm lint && pnpm build` |

## Scope

**In scope**:
- `docs-site/content/docs/adapters/postgresql.mdx`
- `docs-site/content/docs/adapters/mysql.mdx`
- `docs-site/content/docs/adapters/sqlite.mdx`
- `docs-site/content/docs/adapters/mssql.mdx`
- `docs-site/content/docs/adapters/mongo.mdx`
- `docs-site/content/docs/adapters/other-relational-databases.mdx` (major expand)
- `docs-site/content/docs/adapters/community-adapters.mdx` (port upstream delta)
- `docs-site/content/docs/authentication/*.mdx` (copy-first same rules)

**Out of scope**:
- Creating `adapters/drizzle.mdx` or `adapters/prisma.mdx` as standalone pages
- Plugin pages
- Ruby gem implementation

## Git workflow

- Branch: `docs/023-adapters-auth-parity`
- Commit per adapter: `docs(site): copy upstream postgresql adapter doc with Ruby examples`

## Steps

### Step 1: Audit existing relational adapters before rewriting

For **postgresql, mysql, sqlite, mssql**:

1. Compare current local MDX against upstream v1.6.9 section-by-section.
2. If the local page already preserves upstream prose, headings, tables, joins,
   schema generation, and troubleshooting, keep it and only fix broken examples
   or formatting.
3. If a required server-side upstream section is missing, re-copy the upstream
   file and then re-apply correct Ruby examples.
4. Add `<RubyAuthDisclaimer />` after frontmatter if missing.
5. Replace **only** `` ```ts `` blocks with Ruby (see table above).
6. Replace `` ```package-install`` blocks with bash heredocs using `bundle exec better-auth`.
7. Replace Kysely doc links in `<Callout>` with Ruby adapter class names.
8. **Keep unchanged**: intro prose, HTML schema tables, joins explanation,
   non-default schema SQL, troubleshooting callouts, performance links
9. **Delete subsections**: Node.js built-in SQLite, Bun SQLite (sqlite page only)
10. **Add one Ruby subsection** under Example Usage where upstream had multiple drivers:

```ruby title="config/better_auth.rb"
require "better_auth"

auth = BetterAuth.auth(
  secret: ENV.fetch("BETTER_AUTH_SECRET"),
  base_url: ENV.fetch("BETTER_AUTH_URL"),
  database: ->(options) {
    BetterAuth::Adapters::Postgres.new(options, url: ENV.fetch("DATABASE_URL"))
  }
)
```

**PostgreSQL-specific — must retain from upstream:**
- `## Use a non-default schema` (all 3 options + Prerequisites + How it works + Troubleshooting)
- Replace only the TS Pool examples in that section with Ruby URL/`search_path` equivalent

**Line-count gates:**

| File | Min lines after port |
|------|---------------------|
| `postgresql.mdx` | 150 |
| `mysql.mdx` | 85 |
| `sqlite.mdx` | 95 |
| `mssql.mdx` | 100 |

**Verify**:

```bash
wc -l docs-site/content/docs/adapters/{postgresql,mysql,sqlite,mssql}.mdx
rg 'experimental.*joins|Schema generation' docs-site/content/docs/adapters/postgresql.mdx
rg 'non-default schema|search_path' docs-site/content/docs/adapters/postgresql.mdx
rg 'better-sqlite3|bun:sqlite|node:sqlite' docs-site/content/docs/adapters/sqlite.mdx
# expect: no matches (Node drivers removed)

cd docs-site && pnpm lint
```

### Step 2: Audit `adapters/mongo.mdx`

Current `mongo.mdx` is longer than upstream because it includes Ruby-specific
installation/migration detail. Keep those additions if accurate, but compare
against upstream and ensure upstream prose that still applies is present. If it
is not, copy upstream first and then re-apply the Ruby-specific additions.

Required checks:

1. Installation uses `gem "better_auth-mongodb"`
2. Ruby config uses `BetterAuth::Adapters::MongoDB`
3. Upstream "no schema migration for MongoDB" statement is preserved or adapted
4. Any generated-schema section clearly distinguishes SQL from Mongo behavior

**Verify**: `wc -l` ≥ 55; joins section present.

### Step 3: Rebuild `adapters/other-relational-databases.mdx`

This page absorbs content that has no standalone Ruby page.

**3a. Copy upstream** `other-relational-databases.mdx` verbatim (Kysely intro + Core Dialects links + community dialect bullet list).

**3b. Add `<RubyAuthDisclaimer />` and wrap the Kysely community dialect sections:**

```mdx
<UnderDevelopment>
  The dialects listed below are supported by upstream Better Auth via Kysely.
  RubyAuth does not ship drivers for PlanetScale, Neon, Cloudflare D1, etc.
  Use a core adapter (PostgreSQL, MySQL, SQLite, MSSQL) or implement a custom
  adapter — see [Create a database adapter](/docs/guides/create-a-db-adapter).
</UnderDevelopment>
```

Keep the upstream bullet list **inside** the callout so readers see parity scope.

**3c. Add `## ORM integrations`** (content from upstream drizzle.mdx + prisma.mdx, not separate pages):

| Upstream ORM | RubyAuth status | Doc treatment |
|--------------|-----------------|---------------|
| Drizzle | Not available | Port upstream headings (schema generation, joins, table/field renaming); replace code with `<UnderDevelopment>` + link to native SQL adapters |
| Prisma | Not available | Same |
| ActiveRecord (Rails) | **Supported** via `better_auth-rails` | Ruby example from `integrations/rails.mdx`; `config.database_adapter = :active_record` |
| ActiveRecord (non-Rails) | Unclear | `<UnderDevelopment>` — Sinatra README says AR migrations not supported in v1 |
| Sequel / ROM (Hanami) | **Supported** via `better_auth-hanami` | Link to `/docs/integrations/hanami` |

**3d. Keep Ruby-specific additions** from current local file:
- `:memory` adapter table row
- "Choosing an adapter" table (merge below Core Dialects)

**Verify**:

```bash
wc -l docs-site/content/docs/adapters/other-relational-databases.mdx
# expect >= 120

rg 'Drizzle|Prisma|ActiveRecord|UnderDevelopment' docs-site/content/docs/adapters/other-relational-databases.mdx
# expect multiple matches

test ! -f docs-site/content/docs/adapters/drizzle.mdx
test ! -f docs-site/content/docs/adapters/prisma.mdx
```

### Step 4: Port `adapters/community-adapters.mdx`

Create only if plan 020 manifest and sidebar include a supported community
adapter page. If created, copy upstream, adapt links to Ruby community adapter
gems/table, and keep upstream structure.

### Step 5: Authentication providers finish-pass

Same copy-first rules as adapters. Current provider pages are mostly OK-ish by
line count. Do not rewrite them unless section comparison shows missing
server-side content or broken formatting.

| Slug | Upstream lines | Action |
|------|----------------|--------|
| `google.mdx` | 212 upstream / 241 local | Review formatting/copy fidelity |
| `apple.mdx` | 184 upstream / 194 local | Review formatting/copy fidelity |
| `email-password.mdx` | 533 upstream / 166 local | Plan 021 — ensure cross-links match |

For each provider:

1. Compare local MDX with upstream MDX.
2. Replace any TS `socialProviders` config with
   `BetterAuth::SocialProviders.*`.
3. Remove client sign-in examples.
4. **Keep** upstream sections: scopes, advanced options, profile mapping,
   environment tables.
5. Leave pages unchanged if they already satisfy those checks.

**Verify**:

```bash
wc -l docs-site/content/docs/authentication/google.mdx
# expect >= 150

cd docs-site && pnpm build
```

## Test plan

Documentation-only.

```bash
# Adapters must not be thin rewrites
for f in postgresql mysql sqlite mssql; do
  lines=$(wc -l < "docs-site/content/docs/adapters/$f.mdx")
  echo "$f: $lines"
done

rg 'Kysely|better-sqlite3|createAuthClient' docs-site/content/docs/adapters/
# expect: no Kysely/better-sqlite3/client; "Kysely" may appear only inside UnderDevelopment historical context
```

## Done criteria

- [ ] Each existing relational adapter page preserves applicable upstream
      headings/prose/tables and includes Ruby examples only
- [ ] PostgreSQL retains full non-default schema section from upstream
- [ ] `other-relational-databases.mdx` exists if sidebar/manifest expects it,
      and includes ORM integrations + UnderDevelopment dialects
- [ ] No standalone `drizzle.mdx` / `prisma.mdx`
- [ ] Authentication provider pages contain no `createAuthClient`, `` ```ts ``,
      or `npm install better-auth`
- [ ] `email-password.mdx` cross-links to plan 021 output and is not duplicated here
- [ ] `pnpm lint && pnpm build` pass
- [ ] `plans/README.md` row 023 DONE

## STOP conditions

- Local adapter page < 80% upstream lines after port — redo as copy-first, do not submit
- Unsure if Ruby supports an upstream feature — use `<UnderDevelopment>`, keep upstream prose
- Port script strips schema tables or callouts — fix script; do not accept thin output
- Re-copying upstream would delete accurate Ruby-specific sections from the
  current longer adapter pages — preserve those sections and report the merge
  decision instead of overwriting blindly

## Maintenance notes

When adding a Ruby database driver, remove its entry from the UnderDevelopment
dialect list and add a dedicated adapter page using the same copy-first template
from upstream if a matching page exists.

Cross-check `concepts/database.mdx` (plan 021) links to adapter pages after this
plan lands — anchor names should match upstream (`#use-a-non-default-schema`).
