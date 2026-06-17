# Plan 022: Docs Parity — Supported Plugins Copy-First Parity

> **Executor instructions**: Complete plan 020. Plan 021 recommended first.
> Work in batches below; run `pnpm lint && pnpm build` after each batch.
>
> **Drift check (run first)**:
> `git diff --stat 2ce7a4a..HEAD -- docs-site/content/docs/plugins docs-site/components/sidebar-content.tsx docs-site/lib/plugins.ts`

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: plans/020-docs-parity-foundation.md, plans/021-docs-concepts-and-getting-started.md (recommended)
- **Category**: docs
- **Planned at**: commit `2ce7a4a`, 2026-06-16

## Why this matters

Plugin pages are no longer empty stubs, but most supported plugin docs are
still far thinner than upstream. Upstream plugin docs include endpoint
reference, schema tables, configuration, and edge cases that users need before
enabling 2FA, organization, SSO, API keys, SCIM, OAuth provider, and similar
plugins.

This plan is deliberately copy-first: literally copy and paste upstream MDX for
supported plugins, preserve the same prose/headings/tables/callouts/order, and
only adapt examples, install commands, package names, and unsupported/client
sections. Fix malformed code fences after the copy. Do not summarize upstream
pages into short Ruby pages.

## Current state

No plugin pages currently contain the old `See the plugin tests under` stub
boilerplate, but line counts show most pages are still thin compared with
upstream v1.6.9:

| Slug | Upstream lines | Local lines | Status |
|------|----------------|-------------|--------|
| `plugins/organization.mdx` | 2516 | 68 | THIN |
| `plugins/sso.mdx` | 1740 | 68 | THIN |
| `plugins/oauth-provider.mdx` | 2146 | 193 | THIN |
| `plugins/admin.mdx` | 839 | 66 | THIN |
| `plugins/device-authorization.mdx` | 647 | 63 | THIN |
| `plugins/2fa.mdx` | 608 | 94 | THIN |
| `plugins/jwt.mdx` | 552 | 70 | THIN |
| `plugins/generic-oauth.mdx` | 518 | 52 | THIN |
| `plugins/passkey.mdx` | 486 | 153 | THIN |
| `plugins/email-otp.mdx` | 467 | 62 | THIN |
| `plugins/phone-number.mdx` | 412 | 63 | THIN |
| `plugins/last-login-method.mdx` | 407 | 51 | THIN |
| `plugins/scim.mdx` | 624 | 112 | THIN |
| `plugins/magic-link.mdx` | 153 | 55 | THIN |
| `plugins/one-tap.mdx` | 210 | 53 | THIN |
| `plugins/siwe.mdx` | 295 | 64 | THIN |
| `plugins/stripe.mdx` | 1095 | 860 | OK-ish, verify formatting only |
| `plugins/username.mdx` | 361 | 369 | OK-ish, verify formatting only |

**Supported plugin docs to port/finish**:

- Core/plugin-shim docs: `2fa`, `admin`, `anonymous`, `bearer`, `captcha`,
  `device-authorization`, `dub`, `email-otp`, `generic-oauth`,
  `have-i-been-pwned`, `jwt`, `last-login-method`, `magic-link`,
  `multi-session`, `oauth-proxy`, `one-tap`, `one-time-token`, `open-api`,
  `organization`, `phone-number`, `siwe`, `username`
- External gem docs: `api-key`, `passkey`, `sso`, `scim`, `stripe`,
  `oauth-provider`
- Local/support docs: `community-plugins`; `custom-session` only if present or
  added by a separate supported-feature plan

**Explicitly unsupported / remove-if-local**:

- `plugins/mcp.mdx` — delete/omit from docs and official plugin listing
- upstream `plugins/oidc-provider.mdx` — do not create; remove stale
  `oidc-provider` metadata from `docs-site/lib/plugins.ts`
- `plugins/test-utils.mdx` — delete/omit; no public supported plugin
- `plugins/agent-auth.mdx`
- Non-Stripe payment plugins: `autumn`, `chargebee`, `creem`,
  `dodopayments`, `polar`

Do not add stub pages for unsupported plugins. The user requirement is
"only what we support"; unsupported docs should be absent from navigation and
official plugin grids rather than shown as supported.

**Special**:

- `plugins/i18n.mdx` — depends on plan 019 implementation; port upstream doc
  only after `BetterAuth::Plugins.i18n` exists
- `plugins/community-plugins.mdx` — keep community table; align intro with upstream
- `plugins/index.mdx` — create only if navigation expects it; otherwise update
  the existing plugin listing component/data after batch ports

**Plugin factory naming** (use in Installation sections):

```ruby
BetterAuth::Plugins.two_factor(issuer: "My App")
BetterAuth::Plugins.admin
BetterAuth::Plugins.organization
# External — require gem first:
require "better_auth/api_key"
BetterAuth::Plugins.api_key
```

Read factories from `packages/better_auth/lib/better_auth/plugins/*.rb` — do not
guess option keys; match `def self.admin(options = {})` signatures.

## Commands

| Purpose | Command |
|---------|---------|
| Port | `node docs-site/scripts/port-upstream-doc.mjs plugins/2fa.mdx` |
| Find endpoints | `rg 'path:|def.*_endpoint' packages/better_auth/lib/better_auth/plugins/admin.rb` |
| Lint/build | `cd docs-site && pnpm lint && pnpm build` |
| Thin-page check | `ruby -e 'up="reference/upstream-src/1.6.9/repository/docs/content/docs"; Dir["docs-site/content/docs/plugins/*.mdx"].sort.each { |f| rel=f.delete_prefix("docs-site/content/docs/"); u=File.join(up, rel); next unless File.file?(u); puts "#{rel}: #{File.readlines(f).length}/#{File.readlines(u).length}" }'` |
| Unsupported check | `rg 'mcp|oidc-provider|test-utils' docs-site/content/docs/plugins docs-site/lib/plugins.ts docs-site/components/sidebar-content.tsx` should show no supported docs/listing |

## Scope

**In scope**:
- Supported plugin MDX files listed above under `docs-site/content/docs/plugins/`
- Delete/omit unsupported local pages: `docs-site/content/docs/plugins/mcp.mdx`
  and `docs-site/content/docs/plugins/test-utils.mdx`
- `docs-site/components/sidebar-content.tsx` if plugin navigation contains
  unsupported links or needs supported plugin order updates
- `docs-site/lib/plugins.ts` to remove stale `oidc-provider` metadata and ensure
  official plugin grids only show supported pages

**Out of scope**:
- Ruby plugin implementation
- `docs-site/lib/community-plugins-data.ts`

## Git workflow

- Branch: `docs/022-plugins-parity`
- Commit in 4 batches (see Steps)

## Steps

### Batch A — Auth methods (8 pages)

Port: `2fa`, `magic-link`, `email-otp`, `phone-number`, `anonymous`, `username`,
`one-tap`, `siwe`

For each:

1. `node docs-site/scripts/port-upstream-doc.mjs plugins/<name>.mdx`
2. Remove "Add the client plugin" steps entirely
3. Replace `<APIMethod>` inner TS with Ruby `auth.api.*` from tests
4. Add a standard Ruby migration block, preserving any existing local example
   only if it is correctly formatted:

```ruby
plugins: [BetterAuth::Plugins.two_factor(issuer: "My App")]
```

```bash
bundle exec better-auth generate --cwd . --dialect postgres --output db/better_auth/schema.sql
```

**Verify batch A**:

```bash
rg -l 'See the plugin tests under' docs-site/content/docs/plugins/{2fa,magic-link,email-otp,phone-number,anonymous,username,one-tap,siwe}.mdx
# expect: no output

cd docs-site && pnpm lint
```

### Batch B — Session & utility plugins (10 pages)

Port: `multi-session`, `last-login-method`, `bearer`, `jwt`, `one-time-token`,
`oauth-proxy`, `device-authorization`, `generic-oauth`, `captcha`,
`have-i-been-pwned`, `open-api`, `dub`

Note: `bearer`, `captcha`, `last-login-method`, `have-i-been-pwned` are
hook-only (no HTTP endpoints per `upstream_plugin_inventory_test.rb`) — keep
upstream explanation of behavior but show Ruby config-only examples.

**Verify batch B**: same grep/lint pattern.

### Batch C — Admin & organization

Port: `admin`, `organization`

`organization.mdx` is largest (2516 upstream lines). Split work:

1. Port mechanical copy first
2. Schema section: use plugin schema from `organization/schema.rb`
3. API section: map from `organization_test.rb` + `organization_org_crud_test.rb`
4. Access control: document `BetterAuth::Plugins.create_access_control` from
   `access_test.rb`

**Verify**: `organization.mdx` >= 1200 lines after client/unsupported removal
or every omitted upstream section has a documented unsupported/client-only
reason; build passes.

### Batch D — External gems

Port/finish: `api-key`, `passkey`, `sso`, `scim`, `stripe`, `oauth-provider`.

Note: local docs currently use `docs-site/content/docs/plugins/api-key.mdx`,
not an `api-key/` folder. Keep the local route shape unless plan 020 manifest
and sidebar changes intentionally move to nested pages.

Each page must start Installation with:

```ruby
# Gemfile
gem "better_auth-<name>"

# config
require "better_auth/<name>"
```

Use external gem README + tests where upstream differs from core patterns.

**Verify**:

```bash
rg 'better_auth-api-key|better_auth/sso' docs-site/content/docs/plugins/{api-key,sso,scim,stripe,passkey,oauth-provider}.mdx
# multiple matches

cd docs-site && pnpm build
```

### Step 5: Remove unsupported plugin docs/listings

Delete or omit unsupported docs from the public docs surface:

- Remove `docs-site/content/docs/plugins/mcp.mdx`
- Remove `docs-site/content/docs/plugins/test-utils.mdx`
- Ensure no `docs-site/content/docs/plugins/oidc-provider.mdx` exists
- Remove stale `oidc-provider` metadata from `docs-site/lib/plugins.ts`
- Remove any `mcp`, `oidc-provider`, or `test-utils` sidebar/plugin-grid entries

**Verify**:

```bash
test ! -f docs-site/content/docs/plugins/mcp.mdx
test ! -f docs-site/content/docs/plugins/test-utils.mdx
test ! -f docs-site/content/docs/plugins/oidc-provider.mdx
rg 'mcp|oidc-provider|test-utils' docs-site/content/docs/plugins docs-site/lib/plugins.ts docs-site/components/sidebar-content.tsx
# expect no supported-doc/listing matches
```

### Step 6: Update `plugins/index.mdx` or plugin listing data

Align plugin listing with ported pages; mark skip_unported plugins as
"Not yet ported" only if the maintainer explicitly wants visible unsupported
pages. For this request, omit unsupported plugins from navigation and official
plugin grids.

**Verify**: no broken `/docs/plugins/...` links in index.

## Test plan

After all batches:

```bash
# No old stub boilerplate left
rg 'See the plugin tests under' docs-site/content/docs/plugins/
# expect: no matches

# No client leaks
rg 'createAuthClient|authClient\.|```ts|npm install better-auth' docs-site/content/docs/plugins/
# expect: no matches

# No unsupported public plugin docs/listings
test ! -f docs-site/content/docs/plugins/mcp.mdx
test ! -f docs-site/content/docs/plugins/test-utils.mdx
test ! -f docs-site/content/docs/plugins/oidc-provider.mdx

cd docs-site && pnpm lint && pnpm build
```

## Done criteria

- [ ] All supported plugin pages use literal upstream MDX as the base and only
      adapt examples/unsupported sections
- [ ] High-surface pages meet minimum sanity gates or document omissions:
      `organization` >= 1200 lines, `sso` >= 800, `oauth-provider` >= 900,
      `admin` >= 400, `2fa` >= 300
- [ ] Zero `See the plugin tests under` on ported pages
- [ ] Zero `createAuthClient` / `` ```ts `` / `npm install better-auth` in plugins/
- [ ] `mcp`, upstream `oidc-provider`, and `test-utils` are absent from public
      docs pages, sidebar entries, and official plugin-grid metadata
- [ ] External gem pages document `gem` + `require`
- [ ] `pnpm lint && pnpm build` pass
- [ ] `plans/README.md` row 022 DONE

## STOP conditions

- Plugin method in upstream docs has no Ruby equivalent in lib/ or tests — add
  `<UnderDevelopment>` for that section; do not document fantasy endpoints
- External gem not in workspace — stop that page and report (do not document)
- `plugins/i18n.mdx` requested but plan 019 not DONE — skip i18n page
- A page or listing would present `mcp`, upstream `oidc-provider`, or
  `test-utils` as supported — remove it instead of documenting it

## Maintenance notes

When new plugins ship, add manifest entry + port from upstream tag matching
`VERSION.md`. Organization and oauth-provider docs are high-churn — link to
tests prominently for edge cases.
