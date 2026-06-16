# Plan 024: Docs Parity — Reference, Guides & Errors

> **Executor instructions**: Complete plan 020. Can run parallel to 021–023.
>
> **Drift check (run first)**:
> `git diff --stat 0d19370..HEAD -- docs-site/content/docs/reference docs-site/content/docs/guides`

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/020-docs-parity-foundation.md
- **Category**: docs
- **Planned at**: commit `0d19370`, 2026-06-15

## Why this matters

Reference pages (`options`, `security`, error catalog) and guides (migrations,
SSO setup) are thin or missing. Error pages exist but lack upstream context.
`reference/options.mdx` at 218 lines vs upstream 940 leaves configurators
without complete Ruby option docs.

## Current state

**Reference — port/expand**:

| Slug | Upstream lines | Local | Action |
|------|----------------|-------|--------|
| `reference/options.mdx` | 940 | 218 | THIN — major expand |
| `reference/security.mdx` | 290 | 43 | STUB |
| `reference/faq.mdx` | 256 | 66 | THIN |
| `reference/instrumentation.mdx` | 88 | 24 | THIN |
| `reference/contributing.mdx` | 194 | 51 | adapt for Ruby repo |
| `reference/resources.mdx` | 134 | 29 | STUB |
| `reference/telemetry.mdx` | — | exists | align with `better_auth-telemetry` gem |
| `reference/errors/*.mdx` | ~15–40 each | similar | expand body text from upstream |

**Missing error page**: `reference/errors/state_invalid.mdx` — create from upstream

**Keep local**: `reference/errors/please_restart_the_process.mdx`

**Guides — selective port**:

| Slug | Action |
|------|--------|
| `guides/saml-sso-with-okta.mdx` | Port — Ruby SSO gem |
| `guides/dynamic-base-url.mdx` | Port — `base_url` Ruby config |
| `guides/optimizing-for-performance.mdx` | Port — Rack-focused; drop Edge/JS |
| `guides/your-first-plugin.mdx` | **Create Ruby version** from upstream structure |
| `guides/create-a-db-adapter.mdx` | **Create Ruby version** — `BetterAuth::Adapters` |
| `guides/next-auth-migration-guide.mdx` | Port conceptually for Ruby/Devise/OAuth |
| `guides/auth0-migration-guide.mdx` | Same |
| `guides/clerk-migration-guide.mdx` | Same |
| `guides/supabase-migration-guide.mdx` | Same — DB + auth migration |
| `guides/workos-migration-guide.mdx` | Same |
| `guides/browser-extension-guide.mdx` | **skip_client** — browser extension focus |

Migration guides: keep upstream migration *steps* (user export, session strategy)
but replace all TS/Next.js code with Ruby/Rails equivalents.

**Do NOT port**: `infrastructure/**`, `ai-resources/**`, `examples/**`

## Ruby sources for reference

| Page | Source |
|------|--------|
| `options.mdx` | `packages/better_auth/lib/better_auth/configuration.rb`, Rails `option_builder.rb` |
| `security.mdx` | `reference/security.mdx` upstream + Ruby crypto in `lib/better_auth/crypto.rb` |
| `instrumentation.mdx` | `packages/better_auth/lib/better_auth/instrumentation.rb`, telemetry gem |
| `telemetry.mdx` | `packages/better_auth-telemetry/README.md` |
| Error pages | `packages/better_auth/lib/better_auth/errors.rb` |
| `your-first-plugin.mdx` | `packages/better_auth/test/better_auth/plugin_test.rb`, existing plugin files |
| `create-a-db-adapter.mdx` | `packages/better_auth/lib/better_auth/adapters/` |

## Commands

| Purpose | Command |
|---------|---------|
| Port | `node docs-site/scripts/port-upstream-doc.mjs reference/options.mdx` |
| Options grep | `rg 'def initialize|option' packages/better_auth/lib/better_auth/configuration.rb` |
| Verify | `cd docs-site && pnpm lint && pnpm build` |

## Scope

**In scope**:
- `docs-site/content/docs/reference/**` (except keep_local error)
- `docs-site/content/docs/guides/**` (except browser-extension)
- Create: `guides/your-first-plugin.mdx`, `guides/create-a-db-adapter.mdx`,
  `reference/errors/state_invalid.mdx`
- Update `docs-site/components/sidebar-content.tsx` guides section if new pages
  need sidebar entries (guides may already be listed)

**Out of scope**:
- Plugin/concept pages
- `docs-site/content/docs/comparison.mdx` (Ruby-specific, touch only if FAQ overlaps)

## Git workflow

- Branch: `docs/024-reference-guides-parity`
- Commits by section: reference, errors, guides

## Steps

### Step 1: Port `reference/options.mdx`

This is the largest reference task. Workflow:

1. Port upstream MDX mechanically
2. For each option group (session, emailAndPassword, socialProviders, advanced):
   - Verify Ruby config key (snake_case) in `configuration.rb`
   - Replace TS types with Ruby hash syntax
   - Mark unsupported options with `<UnderDevelopment>`
3. Link to `/docs/concepts/*` and `/docs/plugins/*` for plugin options
4. Rails tab: `BetterAuth::Rails.configure do |config| ... end`

**Verify**:

```bash
wc -l docs-site/content/docs/reference/options.mdx
# expect >= 500

rg '```ts' docs-site/content/docs/reference/options.mdx
# no matches

cd docs-site && pnpm lint
```

### Step 2: Port security, faq, instrumentation, resources, telemetry

- `security.mdx`: emphasize server-side secret handling, cookie flags, CSRF — no
  "store token in localStorage" client guidance
- `faq.mdx`: replace Next.js answers with Rails/Rack
- `instrumentation.mdx` + `telemetry.mdx`: document OpenTelemetry-style hooks if
  present; link to telemetry gem
- `contributing.mdx`: point to repo root `AGENTS.md`, Minitest/RSpec, StandardRB
- `resources.mdx`: Ruby community links, gem pages, GitHub repo

**Verify**: each file >= 60 lines; build passes.

### Step 3: Expand error catalog

For each `reference/errors/*.mdx`:

1. Read upstream counterpart
2. Keep short title/description frontmatter
3. Add: When it occurs, HTTP status, example response JSON, how to fix (Ruby context)
4. Create missing `state_invalid.mdx`

**Verify**:

```bash
ls docs-site/content/docs/reference/errors/*.mdx | wc -l
# expect >= 24

cd docs-site && pnpm build
```

### Step 4: Port Ruby-relevant guides

**4a. SAML SSO with Okta** — port; use `better_auth-sso` / SAML gem examples

**4b. Dynamic base URL** — port `base_url` / `trusted_origins` Ruby config

**4c. Optimizing for performance** — port database indexing, session cache;
remove Vercel Edge, Next.js middleware sections

**4d. Your first plugin** — create from upstream `guides/your-first-plugin.mdx`:

```ruby
module BetterAuth
  module Plugins
    module_function

    def hello_world(**options)
      # plugin struct matching BetterAuth::Plugin
    end
  end
end
```

Follow `plugin_test.rb` patterns.

**4e. Create a DB adapter** — create from upstream; document
`BetterAuth::Adapters::Base` interface from `adapters/base.rb`

**4f. Migration guides** — port auth0/clerk/next-auth/supabase/workos:

- Replace TS import blocks with Ruby initializer
- User migration: export CSV → import via `auth.api` admin or custom script
- Session migration: document session invalidation strategy (cannot port JS sessions)
- Add `<RubyAuthDisclaimer />` at top

**Do NOT create** `guides/browser-extension-guide.mdx`

**Verify**:

```bash
test -f docs-site/content/docs/guides/your-first-plugin.mdx
test -f docs-site/content/docs/guides/create-a-db-adapter.mdx
rg 'createAuthClient' docs-site/content/docs/guides/
# no matches

cd docs-site && pnpm lint && pnpm build
```

### Step 5: Sidebar updates (if needed)

Check `docs-site/components/sidebar-content.tsx` guides section includes new pages.
Add entries for `your-first-plugin` and `create-a-db-adapter` if missing.

**Verify**: new guide URLs appear in sidebar grep:

```bash
rg 'your-first-plugin|create-a-db-adapter' docs-site/components/sidebar-content.tsx
```

## Test plan

Documentation-only.

```bash
cd docs-site && pnpm build
# Confirm no broken links in build output
```

## Done criteria

- [ ] `reference/options.mdx` >= 500 lines, Ruby-only code fences
- [ ] All error pages have >= 25 lines body content
- [ ] `state_invalid.mdx` exists
- [ ] Ruby guides created: your-first-plugin, create-a-db-adapter
- [ ] Migration guides ported (5) without TS client code
- [ ] browser-extension guide not added
- [ ] `pnpm lint && pnpm build` pass
- [ ] `plans/README.md` row 024 DONE

## STOP conditions

- Option documented upstream but absent from `configuration.rb` — mark
  UnderDevelopment; do not document fake config keys
- Migration guide requires client SDK steps — omit those sections, add note
- Sidebar structure requires major refactor — stop and report

## Maintenance notes

When Ruby adds config options, update `reference/options.mdx` in same PR.
Error codes should match `BetterAuth::Errors` constants — grep when upstream adds errors.
