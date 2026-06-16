# Plan 022: Docs Parity — Plugins (All Server-Side)

> **Executor instructions**: Complete plan 020. Plan 021 recommended first.
> Work in batches below; run `pnpm lint && pnpm build` after each batch.
>
> **Drift check (run first)**:
> `git diff --stat 0d19370..HEAD -- docs-site/content/docs/plugins`

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: plans/020-docs-parity-foundation.md, plans/021-docs-concepts-and-getting-started.md (recommended)
- **Category**: docs
- **Planned at**: commit `0d19370`, 2026-06-15

## Why this matters

32 of 33 plugin pages are **STUBs** (~38 lines). Upstream plugin docs average
400–2500 lines with endpoint reference, schema tables, and configuration.
Users enabling 2FA, organization, SSO, API keys, etc. currently get no usable
documentation.

## Current state

Stub template (38 lines) appears in all files matching:

```bash
rg -l 'See the plugin tests under' docs-site/content/docs/plugins/
# 30 files
```

**Port list** (`action: port` in manifest) — core gem plugins:

| Slug | Upstream lines | Ruby test / source |
|------|----------------|-------------------|
| `plugins/2fa.mdx` | 608 | `packages/better_auth/test/better_auth/plugins/two_factor_test.rb` |
| `plugins/admin.mdx` | 839 | `packages/better_auth/test/better_auth/plugins/admin_test.rb` |
| `plugins/anonymous.mdx` | 204 | `anonymous_test.rb` |
| `plugins/bearer.mdx` | 149 | `bearer_test.rb` |
| `plugins/captcha.mdx` | (check upstream) | `captcha_test.rb` |
| `plugins/device-authorization.mdx` | 647 | `device_authorization_test.rb` |
| `plugins/dub.mdx` | 154 | `dub_test.rb` |
| `plugins/email-otp.mdx` | 467 | `email_otp_test.rb` |
| `plugins/generic-oauth.mdx` | 518 | `generic_oauth_test.rb` |
| `plugins/have-i-been-pwned.mdx` | (check) | `have_i_been_pwned_test.rb` |
| `plugins/jwt.mdx` | 552 | `jwt_test.rb` |
| `plugins/last-login-method.mdx` | 407 | `last_login_method_test.rb` |
| `plugins/magic-link.mdx` | 153 | `magic_link_test.rb` |
| `plugins/multi-session.mdx` | 108 | `multi_session_test.rb` |
| `plugins/oauth-proxy.mdx` | 102 | `oauth_proxy_test.rb` |
| `plugins/oidc-provider.mdx` | 655 | `oidc_provider_test.rb` |
| `plugins/one-tap.mdx` | 210 | `one_tap_test.rb` |
| `plugins/one-time-token.mdx` | 127 | `one_time_token_test.rb` |
| `plugins/open-api.mdx` | (check) | `open_api_test.rb` |
| `plugins/organization.mdx` | 2516 | `organization_test.rb`, `organization_org_crud_test.rb`, `organization_members_test.rb` |
| `plugins/phone-number.mdx` | 412 | `phone_number_test.rb` |
| `plugins/siwe.mdx` | 295 | `siwe_test.rb` |
| `plugins/username.mdx` | 361 | `username_test.rb` |

**External gem plugins** (add Gemfile section to each):

| Slug | Gem | Test path |
|------|-----|-----------|
| `plugins/api-key/index.mdx` | `better_auth-api-key` | `packages/better_auth-api-key/test/` |
| `plugins/api-key/advanced.mdx` | same | same |
| `plugins/api-key/reference.mdx` | same | same |
| `plugins/passkey.mdx` | `better_auth-passkey` | `packages/better_auth-passkey/test/` |
| `plugins/sso.mdx` | `better_auth-sso` | `packages/better_auth-sso/test/` |
| `plugins/scim.mdx` | `better_auth-scim` | `packages/better_auth-scim/test/` |
| `plugins/stripe.mdx` | `better_auth-stripe` | `packages/better_auth-stripe/test/` |
| `plugins/oauth-provider.mdx` | `better_auth-oauth-provider` | `packages/better_auth-oauth-provider/test/` |
| `plugins/mcp.mdx` | core | `packages/better_auth/test/better_auth/plugins/mcp/` |

**Skip / stub-only** (`action: skip_unported`):

- `plugins/agent-auth.mdx` — not in Ruby inventory
- `plugins/autumn.mdx`, `chargebee.mdx`, `creem.mdx`, `dodopayments.mdx`, `polar.mdx` — billing plugins not ported
- `plugins/test-utils.mdx` — test-only upstream plugin

For skip_unported: either omit from `plugins/meta.json` and sidebar, OR add
short MDX:

```mdx
---
title: Polar
description: Not yet available in RubyAuth.
---
<RubyAuthDisclaimer />
<UnderDevelopment>This plugin is not ported to RubyAuth v1.6.9 parity.</UnderDevelopment>
```

**Special**:

- `plugins/i18n.mdx` — **depends on plan 019** implementation; port upstream
  doc only after `BetterAuth::Plugins.i18n` exists
- `plugins/custom-session.mdx` — **keep_local**; expand using
  `custom_session_test.rb` without overwriting Ruby-specific prose
- `plugins/community-plugins.mdx` — keep community table; align intro with upstream
- `plugins/index.mdx` — update feature grid after batch ports

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
| Batch check | `rg -l 'See the plugin tests under' docs-site/content/docs/plugins/` → should trend to 0 |

## Scope

**In scope**: all `docs-site/content/docs/plugins/**/*.mdx` except skip_unported
(slug list above)

**Out of scope**:
- `plugins/meta.json` order changes unless adding mcp/i18n entries
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
4. Add standard migration block (copy from current stub — it's correct):

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

### Batch C — Admin & organization (3 pages)

Port: `admin`, `organization`, `oidc-provider`

`organization.mdx` is largest (2516 upstream lines). Split work:

1. Port mechanical copy first
2. Schema section: use plugin schema from `organization/schema.rb`
3. API section: map from `organization_test.rb` + `organization_org_crud_test.rb`
4. Access control: document `BetterAuth::Plugins.create_access_control` from
   `access_test.rb`

**Verify**: `organization.mdx` >= 800 lines after client removal; build passes.

### Batch D — External gems (9 pages)

Port: `api-key/index`, `api-key/advanced`, `api-key/reference`, `passkey`, `sso`,
`scim`, `stripe`, `oauth-provider`, `mcp`

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
rg 'better_auth-api-key|better_auth/sso' docs-site/content/docs/plugins/{api-key,sso,scim,stripe,passkey,oauth-provider,mcp}.mdx
# multiple matches

cd docs-site && pnpm build
```

### Step 5: Update `plugins/index.mdx`

Align plugin listing with ported pages; mark skip_unported plugins as
"Not yet ported" in the index grid if they remain in sidebar.

**Verify**: no broken `/docs/plugins/...` links in index.

## Test plan

After all batches:

```bash
# No stub boilerplate left on ported pages
rg 'See the plugin tests under' docs-site/content/docs/plugins/ | wc -l
# expect: 0 for ported pages (skip_unported may differ)

# No client leaks
rg 'createAuthClient|authClient\.' docs-site/content/docs/plugins/
# expect: no matches

cd docs-site && pnpm lint && pnpm build
```

## Done criteria

- [x] All port-list plugin MDX files >= 100 lines (except hook-only plugins >= 80)
- [x] Zero `See the plugin tests under` on ported pages
- [x] Zero `createAuthClient` / `` ```ts `` in plugins/
- [x] External gem pages document `gem` + `require`
- [x] `pnpm lint && pnpm build` pass
- [x] `plans/README.md` row 022 DONE

## STOP conditions

- Plugin method in upstream docs has no Ruby equivalent in lib/ or tests — add
  `<UnderDevelopment>` for that section; do not document fantasy endpoints
- External gem not in workspace — stop that page and report (do not document)
- `plugins/i18n.mdx` requested but plan 019 not DONE — skip i18n page

## Maintenance notes

When new plugins ship, add manifest entry + port from upstream tag matching
`VERSION.md`. Organization and oauth-provider docs are high-churn — link to
tests prominently for edge cases.
