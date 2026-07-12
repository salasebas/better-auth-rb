# Docs parity rules

These rules define the source-of-truth workflow for porting Better Auth v1.6.23
MDX pages into RubyAuth docs.

## Literal upstream copy workflow

The default mistake to avoid: rewriting pages as short Ruby summaries. The
executor must literally copy and paste upstream MDX, preserving upstream prose,
headings, tables, callouts, examples around the examples being replaced, and
section order unless the section is client-only or explicitly unsupported.

For each `port` page:

1. Copy verbatim the upstream file:
   `reference/upstream-src/1.6.23/repository/docs/content/docs/<slug>` to
   `docs-site/content/docs/<slug>` and overwrite local content.
2. Run mechanical transforms from this file: product names, CLI commands, links.
3. Replace only TypeScript/JavaScript code blocks with Ruby from tests or
   HTTP/curl examples for the same endpoint.
4. Delete client-only or unsupported sections. Do not delete server sections.
5. Add `<RubyAuthDisclaimer />` after frontmatter where `installation.mdx` does.
6. Add `<UnderDevelopment>` when Ruby lacks parity for a specific upstream
   section, such as programmatic migrations or a Kysely community dialect. Keep
   the surrounding prose.
7. Run a formatting pass over code fences: matching fence language, no nested
   unclosed fences, no broken indentation, no leftover `[!code ...]` markers.

Line-count sanity check after port, after unsupported and client-only removals:

| Page kind | Expect after copy + client removal |
| --- | --- |
| Adapter (`adapters/postgresql.mdx`) | >= 80% of upstream line count |
| Concept (`concepts/database.mdx`) | >= 70% of upstream line count |
| Plugin stub replacement | >= 50% of upstream line count |

If the local page is less than 50% of upstream lines after port, the executor
rewrote instead of copied. Stop and redo from the upstream file.

## Mechanical replacements

| Upstream pattern | RubyAuth replacement |
| --- | --- |
| `betterAuth({` | `BetterAuth.auth(` |
| `import { betterAuth } from "better-auth"` | `require "better_auth"` |
| `import { admin } from "better-auth/plugins"` | `BetterAuth::Plugins.admin` |
| `admin()` | `BetterAuth::Plugins.admin` |
| `twoFactor()` | `BetterAuth::Plugins.two_factor(...)` |
| `npx auth migrate` / `npx auth@latest migrate` | `bundle exec better-auth migrate --cwd . --config config/better_auth.rb --yes` |
| `npx auth generate` / `npx auth@latest generate` | `bundle exec better-auth generate --cwd . --dialect postgres --output db/better_auth/schema.sql --config config/better_auth.rb` |
| `npm install better-auth` | `gem "better_auth"` + `bundle install` |
| Kysely / `pg` Pool / `mysql2/promise` examples | `BetterAuth::Adapters::Postgres` / `MySQL` / `SQLite` / `MSSQL` - see adapter tests |
| "supported via Kysely adapter" prose | Keep sentence structure; replace "Kysely" with "RubyAuth SQL adapters" and link to `/docs/adapters/other-relational-databases` |
| `drizzle-kit` / `@better-auth/drizzle-adapter` | Move to `/docs/adapters/other-relational-databases#orm-integrations` with `<UnderDevelopment>` - no standalone drizzle page |
| `@better-auth/prisma-adapter` / Prisma client | Same - ActiveRecord section under `#orm-integrations` |
| `process.env.BETTER_AUTH_SECRET` | `ENV.fetch("BETTER_AUTH_SECRET")` |
| `auth.api.signInEmail` | `auth.api.sign_in_email` |
| `authClient.signIn.email` | Delete section - use HTTP `POST /api/auth/sign-in/email` |
| `[!code highlight]` comments | Remove entirely |
| ```` ```ts ```` fences | ```` ```ruby ```` after rewriting content |
| `Better Auth` (product name in prose) | `RubyAuth` where referring to this implementation; keep "Better Auth" when citing upstream design inspiration |

## API method blocks

Keep upstream `<APIMethod path="..." method="POST">` wrappers. Inside them,
replace TypeScript `type foo = { ... }` blocks with:

- Ruby `auth.api` examples when the method exists on `auth.api` in tests.
- Or a `curl`/HTTP example for browser-facing routes.

Find API method names in tests:

```bash
rg 'auth\.api\.' packages/better_auth/test/better_auth/plugins/two_factor_test.rb
```

Match snake_case Ruby names to upstream camelCase paths using existing route
tests. Do not invent endpoints.

## Tabs

| Upstream tabs | RubyAuth tabs |
| --- | --- |
| Next.js / Nuxt / Svelte | Rails / Plain Rack |
| `migrate` / `generate` | keep, with Ruby CLI commands |
| Prisma / Drizzle | Remove tab - link to ActiveRecord / native adapter docs |

## Ruby example sources

Use sources in this priority order:

1. Plugin test file from `docs-site/scripts/docs-parity-manifest.json`
   `ruby_source`.
2. Adapter or integration spec under `packages/better_auth-*/spec` or `test`.
3. `docs-site/content/docs/installation.mdx` patterns for config and
   migrations.
4. If no test covers a documented option, mark the option with
   `<UnderDevelopment>` and link to the upstream issue. Do not fabricate API.

## Exclusions

Never port client-only sections or pages, including sections mentioning
`createAuthClient`, `authClient`, `better-auth/client`, `*Client()` plugins, or
steps titled "Add the client plugin".

Never document unsupported plugins as supported: `mcp`, upstream
`oidc-provider`, `test-utils`, non-Stripe payment plugins, and hosted
infrastructure/product pages.
