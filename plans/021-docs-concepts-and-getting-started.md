# Plan 021: Docs Parity — Concepts & Getting Started

> **Executor instructions**: Follow plan 020 first. Run every verification
> command before moving on. Honor STOP conditions. Update `plans/README.md`
> when done.
>
> **Drift check (run first)**:
> `git diff --stat 0d19370..HEAD -- docs-site/content/docs/concepts docs-site/content/docs/basic-usage.mdx docs-site/content/docs/authentication/email-password.mdx docs-site/content/docs/comparison.mdx docs-site/content/docs/introduction.mdx`

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: plans/020-docs-parity-foundation.md
- **Category**: docs
- **Planned at**: commit `0d19370`, 2026-06-15

## Why this matters

Concept pages (`database`, `plugins`, `oauth`, `session-management`, etc.) are
the hub every plugin and adapter page links to. Most are **THIN** (10–30% of
upstream line count). `basic-usage.mdx` and `authentication/email-password.mdx`
are similarly incomplete. Porting these first gives downstream plugin pages
(022–023) correct cross-links and Ruby configuration patterns.

## Current state

| Slug | Upstream lines | Local lines | Status |
|------|----------------|-------------|--------|
| `concepts/database.mdx` | 1024 | 112 | THIN |
| `concepts/plugins.mdx` | 674 | 95 | THIN |
| `concepts/oauth.mdx` | 603 | 79 | THIN |
| `concepts/session-management.mdx` | 574 | 91 | THIN |
| `concepts/users-accounts.mdx` | 572 | 90 | THIN |
| `concepts/hooks.mdx` | 298 | 80 | THIN |
| `concepts/rate-limit.mdx` | 312 | 52 | THIN |
| `concepts/email.mdx` | (upstream) | 114 | review |
| `concepts/cookies.mdx` | (upstream) | 76 | review |
| `concepts/api.mdx` | (upstream) | 114 | review |
| `concepts/cli.mdx` | (upstream) | 121 | OK-ish |
| `basic-usage.mdx` | 508 | 116 | THIN |
| `authentication/email-password.mdx` | 533 | 49 | STUB |
| `introduction.mdx` | — | 29 | keep structure, expand if upstream adds |
| `comparison.mdx` | — | — | keep Ruby comparison focus |

**Do NOT create** (per plan 020):
- `concepts/client.mdx`
- `concepts/typescript.mdx`

**Exemplar** — target quality matches `docs-site/content/docs/installation.mdx`:
Rails/Rack tabs, CLI commands, `BetterAuth.auth` config, `<RubyAuthDisclaimer />`.

**Ruby test sources**:

| Page | Primary test file |
|------|-------------------|
| `concepts/database.mdx` | `packages/better_auth/test/better_auth/adapter_test.rb`, CLI tests in `packages/better_auth-cli/test/` |
| `concepts/plugins.mdx` | `packages/better_auth/test/better_auth/plugin_test.rb` |
| `concepts/oauth.mdx` | `packages/better_auth/test/better_auth/social_providers_test.rb` |
| `concepts/session-management.mdx` | `packages/better_auth/test/better_auth/session_test.rb` |
| `concepts/hooks.mdx` | `packages/better_auth/test/better_auth/hooks_test.rb` |
| `concepts/rate-limit.mdx` | `packages/better_auth/test/better_auth/rate_limit_test.rb` |
| `basic-usage.mdx` | `packages/better_auth/test/better_auth/api_test.rb` |
| `email-password.mdx` | `packages/better_auth/test/better_auth/email_password_test.rb` |

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Port page | `node docs-site/scripts/port-upstream-doc.mjs concepts/database.mdx` | writes MDX |
| Typecheck | `cd docs-site && pnpm lint` | exit 0 |
| Build | `cd docs-site && pnpm build` | exit 0 |
| Find API usage | `rg 'auth\.api\.' packages/better_auth/test/better_auth/` | reference |

## Scope

**In scope** — port and Ruby-ify:

- `docs-site/content/docs/concepts/database.mdx`
- `docs-site/content/docs/concepts/plugins.mdx`
- `docs-site/content/docs/concepts/oauth.mdx`
- `docs-site/content/docs/concepts/session-management.mdx`
- `docs-site/content/docs/concepts/users-accounts.mdx`
- `docs-site/content/docs/concepts/hooks.mdx`
- `docs-site/content/docs/concepts/rate-limit.mdx`
- `docs-site/content/docs/concepts/email.mdx`
- `docs-site/content/docs/concepts/cookies.mdx`
- `docs-site/content/docs/concepts/api.mdx`
- `docs-site/content/docs/concepts/cli.mdx` (expand only where upstream has extra sections)
- `docs-site/content/docs/basic-usage.mdx`
- `docs-site/content/docs/authentication/email-password.mdx`

**Out of scope**:
- Plugin pages (`plans/022`)
- `sidebar-content.tsx` unless a new concept page is added (none expected)
- Ruby gem code changes

## Git workflow

- Branch: `docs/021-concepts-parity`
- Commits: one per page or one commit per `concepts/` batch
- Example: `docs(site): port concepts/database from upstream v1.6.9`

## Steps

### Step 1: Port `concepts/database.mdx`

```bash
node docs-site/scripts/port-upstream-doc.mjs concepts/database.mdx
```

**Copy-first — do NOT keep the current 112-line Ruby summary.** Upstream is
1024 lines covering CLI, programmatic migrations, core schema, custom tables,
ID generation, hooks, plugin schemas, secondary storage, etc.

Then manually:

1. Add `<RubyAuthDisclaimer />` after frontmatter
2. Replace **only** code blocks (TS → Ruby, `npx auth` → `bundle exec better-auth`)
3. **Keep all upstream headings and prose** for server-applicable sections
4. Drizzle/Prisma adapter mentions → link to
   `/docs/adapters/other-relational-databases#orm-integrations` (plan 023)
5. Kysely references → "RubyAuth SQL adapters" + link to adapter pages
6. Use `DatabaseSchema` MDX component where upstream shows SQL schema tables
7. Sections with **no Ruby equivalent yet** — wrap in `<UnderDevelopment>` but
   **keep upstream explanatory text** where it still educates:
   - `getMigrations` / programmatic migrations (no Ruby API found in workspace)
   - Secondary storage details if redis-storage gem docs incomplete
8. Do **not** delete core schema tables, ID generation, or plugin schema sections

**Verify**:

```bash
wc -l docs-site/content/docs/concepts/database.mdx
# expect >= 700 (1024 upstream minus client/ORM sections removed)

rg -n 'createAuthClient|better-auth/client|```ts' docs-site/content/docs/concepts/database.mdx
# expect: no matches

cd docs-site && pnpm lint
```

### Step 2: Port remaining concept pages (copy-first workflow)

For each file in scope list — **overwrite with upstream, do not expand the current
thin local summary in place**:

1. Run port script (literal copy + mechanical transforms)
2. Delete client-only sections only
3. Replace code blocks using the test file from the table above
4. Preserve upstream heading structure (`##`, `###`) and `<APIMethod>` blocks
5. Update internal links: `/docs/...` paths should match RubyAuth slugs
6. Unverified Ruby features → `<UnderDevelopment>` around the code example only;
   keep upstream explanatory prose

**Special cases**:

- `concepts/plugins.mdx`: document lazy loading
  (`BetterAuth::Plugins.method_missing` in `plugins.rb`); list plugins available
  in core vs external gems (table from plan 020 manifest)
- `concepts/oauth.mdx`: use `BetterAuth::SocialProviders.github(...)` pattern
  from `authentication/github.mdx`
- `concepts/rate-limit.mdx`: document Rack-level rate limiting; no Edge middleware
- `concepts/api.mdx`: document `auth.api.*` snake_case methods; show
  `headers: {"cookie" => cookie}` pattern from tests

**Verify after each batch**:

```bash
cd docs-site && pnpm lint && pnpm build
```

### Step 3: Port `basic-usage.mdx`

Upstream covers sign-up, sign-in, sign-out, session get, and server-side
`auth.api` usage. Ruby version must:

- Show HTTP routes (`POST /api/auth/sign-up/email`, etc.)
- Show `auth.api.sign_in_email(body: {...})` from Ruby
- Explicitly state: no official browser client gem — use fetch/HTMX/Turbo
- Match `docs-site/content/docs/authentication/github.mdx` tone for HTTP examples

**Verify**:

```bash
rg 'authClient|createAuthClient' docs-site/content/docs/basic-usage.mdx
# no matches

rg 'sign_in_email|sign-up/email' docs-site/content/docs/basic-usage.mdx
# at least one match each
```

### Step 4: Port `authentication/email-password.mdx`

Upstream is 533 lines covering configuration, hooks, password reset, etc.

Ruby sources: `packages/better_auth/test/better_auth/email_password_test.rb`

Include:

- `email_and_password` config block (Rails initializer style + plain `BetterAuth.auth`)
- Password reset flow HTTP paths
- Hashing options (`password_hasher: :bcrypt` requires bcrypt gem)

Remove:

- Next.js server action examples
- Client `signIn.email()` calls

**Verify**: line count >= 200; `pnpm build` passes.

## Test plan

Documentation-only. No new Ruby tests.

Spot-check rendered pages locally if dev server available:

```bash
cd docs-site && pnpm dev
# visit /docs/concepts/database, /docs/basic-usage, /docs/authentication/email-password
```

## Done criteria

- [x] All 13 in-scope MDX files ported; none contain `createAuthClient`, `` ```ts ``, or `npx auth`
- [x] `concepts/database.mdx` >= 400 lines; `email-password.mdx` >= 200 lines
- [x] `cd docs-site && pnpm lint && pnpm build` exit 0
- [x] No files outside scope modified
- [x] `plans/README.md` row 021 updated to DONE

## STOP conditions

- Plan 020 tooling missing — run 020 first
- Upstream section documents feature with zero Ruby tests and no plugin file —
  add `<UnderDevelopment>` callout; do not invent API
- `pnpm build` fails on MDX component unknown — check component exported in
  `docs-site/app/docs/[[...slug]]/page.tsx` MDX map; stop if new component needed

## Maintenance notes

Plugin pages (022) will link here — keep heading anchors stable (`#schema`, `#usage`, etc.) when possible to match upstream anchor names.
