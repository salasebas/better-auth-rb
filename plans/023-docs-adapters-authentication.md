# Plan 023: Docs Parity — Adapters, Database & Authentication Providers

> **Executor instructions**: Complete plan 020. **Copy upstream verbatim first**
> — do NOT rewrite adapter pages as short Ruby summaries (that is the current
> broken state). Run verification after each section.
>
> **Drift check (run first)**:
> `git diff --stat 0d19370..HEAD -- docs-site/content/docs/adapters docs-site/content/docs/authentication docs-site/content/docs/concepts/database.mdx`

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/020-docs-parity-foundation.md
- **Category**: docs
- **Planned at**: commit `0d19370`, 2026-06-15 (revised 2026-06-15 — adapter copy-first)

## Why this matters

Local adapter pages were **hand-written summaries** (~51–72 lines) instead of
upstream parity (~100–190 lines). They are missing entire upstream sections:

- Intro paragraphs and database product links
- **Schema generation & migration** support tables
- **Joins (Experimental)** with `experimental: { joins: true }` (Ruby supports this — see `configuration_test.rb`, `internal_adapter_test.rb`)
- **Use a non-default schema** (PostgreSQL — full troubleshooting block)
- SQLite multi-driver sections (Node/Bun — remove; keep Ruby `sqlite3` equivalent)
- **Additional Information** / performance links

The user requirement: **same content as upstream, replace examples only, remove
client-only**. Unclear Ruby support (ActiveRecord outside Rails, Kysely community
dialects, Drizzle/Prisma) goes in `other-relational-databases.mdx` with
`<UnderDevelopment>` — not omitted silently.

## Current state — upstream vs local (v1.6.9)

| Slug | Upstream lines | Local lines | Problem |
|------|----------------|-------------|---------|
| `adapters/postgresql.mdx` | 189 | 72 | Missing joins, non-default schema, schema table |
| `adapters/mysql.mdx` | 100 | 63 | Missing joins, intro, schema table |
| `adapters/sqlite.mdx` | 134 | 51 | Missing joins, schema table; only Ruby config |
| `adapters/mssql.mdx` | 131 | 62 | Missing joins, Kysely→Ruby note |
| `adapters/mongo.mdx` | 61 | 58 | Close but missing joins section |
| `adapters/other-relational-databases.mdx` | 46 | 56 | Local rewrite; missing upstream Kysely dialect list |
| `adapters/drizzle.mdx` | 179 | **missing** | Merge into other-relational |
| `adapters/prisma.mdx` | 96 | **missing** | Merge into other-relational |
| `concepts/database.mdx` | 1024 | 112 | THIN — separate plan 021 but adapter cross-links must match |

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
| Port (copy-first) | `node docs-site/scripts/port-upstream-doc.mjs adapters/postgresql.mdx` |
| Line-count check | `wc -l docs-site/content/docs/adapters/postgresql.mdx` (expect ≥ 150) |
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

### Step 1: Port relational adapters (copy-first, section-by-section)

For **postgresql, mysql, sqlite, mssql** — same workflow each:

1. **Overwrite** local file with upstream v1.6.9 MDX (via port script or literal copy)
2. Add `<RubyAuthDisclaimer />` after frontmatter
3. Replace **only** `` ```ts `` blocks with Ruby (see table above)
4. Replace `` ```package-install`` blocks with bash heredocs using `bundle exec better-auth`
5. Replace Kysely doc links in `<Callout>` with Ruby adapter class names
6. **Keep unchanged**: intro prose, HTML schema tables, joins explanation,
   non-default schema SQL, troubleshooting callouts, performance links
7. **Delete subsections**: Node.js built-in SQLite, Bun SQLite (sqlite page only)
8. **Add one Ruby subsection** under Example Usage where upstream had multiple drivers:

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

### Step 2: Port `adapters/mongo.mdx`

Copy upstream, then:

1. Replace Installation `@better-auth/mongo-adapter` with `gem "better_auth-mongodb"`
2. Replace TS example with existing Ruby config from current local file (it is correct — graft into upstream structure)
3. **Keep** upstream joins section with Ruby `experimental: { joins: true }` example
4. Keep "no schema migration for MongoDB" upstream statement

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

Copy upstream, adapt links to Ruby community adapters gem/table in
`docs-site/content/docs/adapters/community-adapters.mdx` — keep upstream structure.

### Step 5: Authentication providers (copy-first)

Same copy-first rules as adapters. Local pages like `github.mdx` (~56 lines) are
acceptable **only if** upstream is similarly short. For THIN providers:

| Slug | Upstream lines | Action |
|------|----------------|--------|
| `google.mdx` | 212 | Full copy-first port |
| `apple.mdx` | 184 | Full copy-first port |
| `email-password.mdx` | 533 | Plan 021 — ensure cross-links match |

For each provider:

1. Copy upstream MDX
2. Replace TS `socialProviders` config with `BetterAuth::SocialProviders.*`
3. Remove client sign-in examples
4. **Keep** upstream sections: scopes, advanced options, profile mapping, env tables

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

- [ ] Each relational adapter page ≥ min line count; includes schema table + joins sections
- [ ] PostgreSQL retains full non-default schema section from upstream
- [ ] `other-relational-databases.mdx` ≥ 120 lines with ORM integrations + UnderDevelopment dialects
- [ ] No standalone `drizzle.mdx` / `prisma.mdx`
- [ ] THIN auth providers (google, apple) ≥ 150 lines
- [ ] `pnpm lint && pnpm build` pass
- [ ] `plans/README.md` row 023 DONE

## STOP conditions

- Local adapter page < 80% upstream lines after port — redo as copy-first, do not submit
- Unsure if Ruby supports an upstream feature — use `<UnderDevelopment>`, keep upstream prose
- Port script strips schema tables or callouts — fix script; do not accept thin output

## Maintenance notes

When adding a Ruby database driver, remove its entry from the UnderDevelopment
dialect list and add a dedicated adapter page using the same copy-first template
from upstream if a matching page exists.

Cross-check `concepts/database.mdx` (plan 021) links to adapter pages after this
plan lands — anchor names should match upstream (`#use-a-non-default-schema`).
