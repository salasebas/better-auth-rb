# Plan 029: Upstream `auth.api` Naming Parity (Ruby Idiomatic)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report; do not improvise. When done, update the status row for this plan in
> `plans/README.md` unless a reviewer told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat f7a6f9a..HEAD -- scripts/generate-endpoint-inventory.rb scripts/compare-endpoint-api-names.rb reference/endpoints-inventory.json reference/endpoints-api-comparison.json packages/better_auth/lib/better_auth/core.rb packages/better_auth/lib/better_auth/plugins packages/better_auth/test/better_auth/plugins/open_api_test.rb packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider.rb packages/better_auth-oauth-provider/README.md packages/better_auth-scim/lib packages/better_auth-sso/lib packages/better_auth-passkey/lib packages/better_auth-api-key/lib packages/better_auth-stripe/lib reference/`
>
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against live code before proceeding. A mismatch is a
> STOP condition unless it is only line-number drift and the named symbols still
> have the same behavior.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: `plans/027-endpoint-contract-cleanup.md` (for removing
  `/forget-password/email-otp` — do **not** duplicate that work here)
- **Coordinates with**: `plans/028-stable-resource-oriented-http-api.md` (HTTP
  path redesign is separate; this plan only renames/consolidates Ruby endpoint
  registry keys and documents client mapping)
- **Category**: migration, tech-debt, docs
- **Planned at**: commit `f7a6f9a`, 2026-06-17

## Why this matters

RubyAuth exposes server-side endpoints as `auth.api.*` methods derived from
endpoint registry keys. Upstream Better Auth v1.6.9 exposes the same routes
through `auth.api.*` in camelCase (`auth.api.createOAuthClient`,
`auth.api.requestPasswordResetEmailOTP`). Most Ruby plugins already follow the
same semantics in snake_case, but:

- there is no **authoritative upstream registry manifest** checked into the repo;
- the comparison script (`scripts/compare-endpoint-api-names.rb`) still mis-reads
  some upstream exports and reports false mismatches;
- a few Ruby registry keys are **duplicate aliases** for the same route (OAuth
  provider list/get client and consent endpoints);
- acronym normalization (`OAuth` → `oauth`, `SCIM` → `scim`) is undocumented,
  which makes maintainers guess whether `create_oauth_client` is correct;
- RubyAuth today still uses legacy `_o_auth_` / `_o_auth2_` segments (e.g.
  `create_o_auth_client`, `o_auth2_token`) that split the acronym into loose
  letters — **this plan replaces them with compact `oauth` / `oauth2` tokens**.

Before shipping RubyAuth as a stable product surface, every supported endpoint
should have one canonical Ruby `auth.api` name that maps predictably to upstream
semantics, with machine-checked parity and a published policy for future plugins
(including the future `@rubyauth/client` path mapping).

## Current state

### Server API derivation (Ruby)

`BetterAuth::API#define_endpoint_methods` converts each endpoint registry key to
the public method name using the same camelCase→snake_case helper:

```62:67:packages/better_auth/lib/better_auth/api.rb
    def normalize_method_name(key)
      key.to_s
        .gsub(/([a-z\d])([A-Z])/, '\1_\2')
        .tr("-", "_")
        .downcase
        .to_sym
    end
```

Example: registry key `:request_password_reset_email_otp` →
`auth.api.request_password_reset_email_otp`.

### Upstream server API derivation (TS)

Upstream plugin `endpoints:` hashes use camelCase registry keys that become
`auth.api` methods with the same spelling (`requestPasswordResetEmailOTP`,
`createOAuthClient`). Documented in upstream
`docs/content/docs/concepts/api.mdx` and inline route docblocks (e.g.
`packages/better-auth/src/plugins/email-otp/routes.ts:707-711`).

### Email OTP password reset (canonical vs deprecated)

| Path | Upstream `auth.api` | Ruby `auth.api` today | Upstream browser client |
| --- | --- | --- | --- |
| `POST /email-otp/request-password-reset` | `requestPasswordResetEmailOTP` | `request_password_reset_email_otp` | `authClient.emailOtp.requestPasswordReset` |
| `POST /forget-password/email-otp` (deprecated) | `forgetPasswordEmailOTP` | `forget_password_email_otp` | `authClient.forgetPassword.emailOtp` |

Removing the deprecated route/alias is **Plan 027 Step 1**, not this plan.

### OAuth provider naming decision (RubyAuth — migrate away from `_o_auth_`)

RubyAuth **today** uses legacy `_o_auth_` / `_o_auth2_` segments in registry keys
and README examples:

```28:39:packages/better_auth-oauth-provider/README.md
client = auth.api.register_o_auth_client(
  headers: {"cookie" => session_cookie},
  body: {
    client_name: "Example Client",
    ...
  }
)
```

**Target after this plan** (maintainer decision): compact acronym tokens — no
loose `_o_` / `_auth_` splits:

| Upstream `auth.api` | Legacy Ruby (remove) | Canonical Ruby (keep) |
| --- | --- | --- |
| `registerOAuthClient` | `register_o_auth_client` | `register_oauth_client` |
| `createOAuthClient` | `create_o_auth_client` | `create_oauth_client` |
| `adminCreateOAuthClient` | `admin_create_o_auth_client` | `admin_create_oauth_client` |
| `getOAuthClient` | `get_o_auth_client` | `get_oauth_client` |
| `getOAuthClients` | `get_o_auth_clients`, `list_o_auth_clients` | `get_oauth_clients` |
| `updateOAuthClient` | `update_o_auth_client` | `update_oauth_client` |
| `deleteOAuthClient` | `delete_o_auth_client` | `delete_oauth_client` |
| `rotateClientSecret` | `rotate_o_auth_client_secret` | `rotate_oauth_client_secret` |
| `getOAuthConsent` | `get_o_auth_consent` | `get_oauth_consent` |
| `getOAuthConsents` | `get_o_auth_consents`, `list_o_auth_consents` | `get_oauth_consents` |
| `updateOAuthConsent` | `update_o_auth_consent` | `update_oauth_consent` |
| `deleteOAuthConsent` | `delete_o_auth_consent` | `delete_oauth_consent` |
| `getOAuthServerConfig` | `get_o_auth_server_config` | `get_oauth_server_config` |
| `getOpenIdConfig` | `get_open_id_config` | `get_openid_config` |
| `oAuth2Authorize` / protocol routes | `o_auth2_authorize`, … | `oauth2_authorize`, … |

Apply the same `oauth2` token to generic OAuth plugin keys (e.g.
`o_auth2_callback` → `oauth2_callback`, `o_auth2_link_account` →
`oauth2_link_account`).

Do **not** introduce `_o_auth_`, `_o_auth2_`, or other split-acronym segments in
new registry keys.

### Core duplicate aliases (intentional compat — consolidate policy)

```34:37:packages/better_auth/lib/better_auth/core.rb
        list_accounts: Routes.list_accounts,
        list_user_accounts: Routes.list_accounts,
        link_social: Routes.link_social,
        link_social_account: Routes.link_social,
```

Upstream exposes one registry key per route; Ruby keeps two names pointing at the
same endpoint object.

### Tooling already present

- `scripts/generate-endpoint-inventory.rb` → `reference/endpoints-inventory.*`
  (includes `ruby_api_call`)
- `scripts/compare-endpoint-api-names.rb` →
  `reference/endpoints-api-comparison.*` (upstream scan still noisy)

### Naming policy target (what “parity” means)

For every supported route:

1. **One canonical Ruby registry key** per path+method (no duplicate aliases
   unless explicitly documented as temporary deprecated compat with a removal
   date).
2. Canonical key = upstream registry key converted with the acronym-aware rules
   in Step 1 below.
3. `auth.api.<canonical_key>` is the documented server API.
4. HTTP path + JSON wire format stay upstream-compatible (no REST redesign — that
   is Plan 028).
5. Future `@rubyauth/client` uses upstream path→client nesting; document mapping
   in reference only (no npm package in this plan).

## Commands you will need

| Purpose | Command | Expected on success |
| --- | --- | --- |
| Regenerate Ruby inventory | `ruby scripts/generate-endpoint-inventory.rb` | exit 0; updates `reference/endpoints-inventory.md/json` |
| Generate upstream registry | `ruby scripts/generate-upstream-endpoint-registry.rb` | exit 0; writes `reference/upstream-endpoint-registry.json` |
| Compare naming parity | `ruby scripts/compare-endpoint-api-names.rb` | exit 0; `api_name_mismatch_count` is 0 for supported routes |
| Core tests | `bundle exec rake test` | exit 0 |
| OAuth provider tests | `cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test` | exit 0 |
| Lint | `bundle exec standardrb` | exit 0 |
| Workspace CI | `bundle exec rake ci` | exit 0 |

## Scope

**In scope**:

- `reference/ruby-api-naming-policy.md` (new)
- `reference/upstream-endpoint-registry.json` (new, generated)
- `scripts/generate-upstream-endpoint-registry.rb` (new)
- `scripts/compare-endpoint-api-names.rb` (upgrade to use registry + policy)
- `scripts/generate-endpoint-inventory.rb` (add `upstream_api_method` column when
  registry is present)
- `packages/better_auth/test/better_auth/endpoint_registry_parity_test.rb` (new)
- Endpoint registry hashes and tests in:
  - `packages/better_auth/lib/better_auth/core.rb`
  - `packages/better_auth/lib/better_auth/plugins/**/*.rb`
  - `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider.rb`
  - external plugin packages under `packages/better_auth-*` that register
    endpoints (scim, sso, passkey, api-key, stripe)
- Package README API tables where they list `auth.api.*` methods
- `reference/endpoints-inventory.md/json`, `reference/endpoints-api-comparison.md/json`

**Out of scope** (do NOT touch):

- Removing `/forget-password/email-otp` — Plan 027
- Passkey GET→POST, OpenAPI duplicate field cleanup, Stripe metadata — Plan 027
- HTTP path redesign (`/organization/update` → REST resources) — Plan 028
- Publishing `@rubyauth/client` npm package — document mapping only
- `reference/upstream-src/**`
- `docs-site/**` (unless a maintainer explicitly expands scope)

## Git workflow

- Branch: `feat/upstream-auth-api-naming-parity`
- Suggested commits:
  1. `docs(reference): add ruby api naming policy and upstream registry`
  2. `chore(scripts): harden endpoint api comparison tooling`
  3. `refactor(oauth): rename auth.api keys from o_auth to oauth`
  4. `refactor(oauth-provider): drop duplicate auth.api registry aliases`
  5. `refactor(core): canonicalize duplicate endpoint registry keys`
  6. `test(auth): add endpoint registry parity coverage`
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Publish Ruby API naming policy

Create `reference/ruby-api-naming-policy.md` with these rules (expand with
examples):

**Registry key → `auth.api` method**

- Convert upstream camelCase registry key to snake_case.
- `auth.api` method name equals registry key (already true today).

**Acronym segments** (apply in order when converting upstream keys):

| Upstream segment | Ruby segment | Example upstream → Ruby |
| --- | --- | --- |
| `OAuth` | `oauth` | `createOAuthClient` → `create_oauth_client` |
| `OAuth2` | `oauth2` | `oAuth2Token` → `oauth2_token` |
| `OpenAPI` | `openapi` | `generateOpenAPISchema` → `generate_openapi_schema` |
| `OpenId` / `OIDC` | `openid` / `oidc` | `getOpenIdConfig` → `get_openid_config` |
| `SCIM` | `scim` | `listSCIMUsers` → `list_scim_users` |
| `SSO` | `sso` | `registerSSOProvider` → `register_sso_provider` |
| `OTP` | `otp` | `signInEmailOTP` → `sign_in_email_otp` |
| `JWT` | `jwt` | `getJwks` → `get_jwks` |
| `URL` | `url` | embedded in field names only |
| `API` | `api` | `createApiKey` → `create_api_key` |
| `SIWE` | `siwe` | `getSiweNonce` → `get_siwe_nonce` |

**Forbidden patterns** in new or renamed registry keys:

- `_o_auth_`, `_o_auth2_`, `_o_idc_`, `_open_id_` (split acronyms with loose letters)
- Duplicate registry keys for the same path+method

**Browser client mapping (document only)**

- Upstream: `createAuthClient()` → `authClient.*` from HTTP paths.
- RubyAuth future package: `@rubyauth/client` follows the **same paths**; only
  the npm scope/branding differs.
- Do not rename HTTP paths in this plan.

**Alias policy**

- At most one canonical registry key per path+method.
- Temporary compat aliases require `@deprecated` note in policy + test asserting
  alias maps to same endpoint object; remove in next breaking release.

**Verify**:

```bash
test -f reference/ruby-api-naming-policy.md
rg -n "create_oauth_client|createOAuthClient|Forbidden patterns" reference/ruby-api-naming-policy.md
rg -n "_o_auth_" reference/ruby-api-naming-policy.md && exit 1 || true
```

Expected: policy file exists, documents `oauth`/`oauth2` mapping, and does not
recommend `_o_auth_` segments.

### Step 2: Generate upstream endpoint registry manifest

Add `scripts/generate-upstream-endpoint-registry.rb` that scans
`reference/upstream-src/1.6.9/repository/packages/**` and emits
`reference/upstream-endpoint-registry.json` with entries:

```json
{
  "generated_at": "...",
  "upstream_version": "1.6.9",
  "entries": [
    {
      "plugin_id": "email-otp",
      "registry_key": "requestPasswordResetEmailOTP",
      "ruby_registry_key": "request_password_reset_email_otp",
      "path": "/email-otp/request-password-reset",
      "method": "POST",
      "upstream_api": "auth.api.requestPasswordResetEmailOTP",
      "ruby_api": "auth.api.request_password_reset_email_otp",
      "upstream_client": "authClient.emailOtp.requestPasswordReset",
      "deprecated": false,
      "source_file": "packages/better-auth/src/plugins/email-otp/index.ts"
    }
  ]
}
```

Implementation requirements:

1. Parse plugin `endpoints: { key: ... }` blocks from upstream `index.ts` /
   package entry files (`packages/oauth-provider/src/oauth.ts`,
   `packages/better-auth/src/plugins/*/index.ts`, `packages/scim/src/index.ts`,
   `packages/passkey/src/index.ts`, `packages/api-key/src/index.ts`,
   `packages/stripe/src/index.ts`, core routes under
   `packages/better-auth/src/api/routes/index.ts`).
2. For each registry key, resolve path+method by reading the referenced
   `createAuthEndpoint("...", { method: ... })` export (follow the symbol name in
   the same package — do not guess from nearby comments).
3. Apply the acronym rules from Step 1 to compute `ruby_registry_key`.
4. Mark `deprecated: true` when upstream docblock contains `@deprecated`.
5. Skip test-only routes (`*.test.ts`, `/body`, `/cookie`, etc.) via denylist
   prefix list maintained in the script.

**Verify**:

```bash
ruby scripts/generate-upstream-endpoint-registry.rb
ruby -rjson -e 'r=JSON.parse(File.read("reference/upstream-endpoint-registry.json")); e=r.fetch("entries"); abort "missing email otp" unless e.any? { |x| x["path"]=="/email-otp/request-password-reset" && x["ruby_registry_key"]=="request_password_reset_email_otp" }; abort "missing oauth create" unless e.any? { |x| x["registry_key"]=="createOAuthClient" && x["ruby_registry_key"]=="create_oauth_client" }; abort "legacy o_auth key leaked" if e.any? { |x| x["ruby_registry_key"].to_s.include?("_o_auth_") }; puts e.length'
```

Expected: script exits 0; entry count is roughly 200+; email-otp and OAuth
create-client mappings present.

### Step 3: Harden comparison tooling

Update `scripts/compare-endpoint-api-names.rb` to:

1. Prefer `reference/upstream-endpoint-registry.json` over raw
   `createAuthEndpoint` scanning.
2. Compare Ruby inventory rows against registry entries by `[method, path]`.
3. Treat `upstream_api_normalized` vs `ruby_api_normalized` using the acronym
   rules from Step 1 (shared helper — extract to
   `scripts/support/endpoint_naming.rb` if needed).
4. Emit sections:
   - `aligned`
   - `missing_ruby` (upstream supported route absent from Ruby inventory)
   - `missing_upstream` (Ruby route not in upstream registry — flag Ruby-only)
   - `registry_key_mismatch` (path matches but canonical Ruby key differs)
   - `deprecated_upstream_still_in_ruby`
5. Exit non-zero when `registry_key_mismatch` or `missing_ruby` is non-empty for
   non-deprecated upstream entries (so CI can gate parity).

Update `scripts/generate-endpoint-inventory.rb` to add columns when registry
exists:

- `upstream_registry_key`
- `upstream_api_call`
- `upstream_client_call`

**Verify**:

```bash
ruby scripts/generate-upstream-endpoint-registry.rb
ruby scripts/generate-endpoint-inventory.rb
ruby scripts/compare-endpoint-api-names.rb
rg -n "request_password_reset_email_otp" reference/endpoints-inventory.md reference/endpoints-api-comparison.md
```

Expected: email OTP canonical route shows aligned; comparison report lists
`forget-password/email-otp` under deprecated section only (until Plan 027 lands).

### Step 4: Rename OAuth registry keys from `_o_auth_` to `oauth`

This is a **breaking rename** for Ruby server callers (`auth.api.*`). No external
users are known yet; do not keep long-lived `_o_auth_` aliases.

1. In `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider.rb`,
   rename every endpoint registry key using the mapping table in "Current state"
   (`create_o_auth_client` → `create_oauth_client`, `o_auth2_token` →
   `oauth2_token`, `get_open_id_config` → `get_openid_config`, etc.).
2. In `packages/better_auth/lib/better_auth/plugins/generic_oauth.rb`, rename
   `o_auth2_callback` → `oauth2_callback`, `o_auth2_link_account` →
   `oauth2_link_account`.
3. Update all call sites:

```bash
rg -n "_o_auth_|o_auth2_|get_open_id_config|open_api_schema" packages examples docs-site reference
```

4. Update `packages/better_auth-oauth-provider/README.md` and any other README
   route tables to show `auth.api.create_oauth_client`, not `create_o_auth_client`.
5. Update `open_api_test.rb` / plugin tests only where they reference renamed
   registry keys (operationId strings stay upstream camelCase).

**Verify**:

```bash
cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test
cd ../.. && bundle exec rake test
rg -n "_o_auth_|\\bo_auth2_" packages/better_auth-oauth-provider packages/better_auth/lib/better_auth/plugins/generic_oauth.rb
```

Expected: tests pass; no `_o_auth_` or `o_auth2_` registry keys remain in those
packages (grep exits 1).

### Step 5: Consolidate OAuth provider duplicate registry keys

In `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider.rb`:

1. Remove duplicate keys `list_oauth_clients` and `list_oauth_consents` if they
   were recreated during Step 4 — keep only:
   - `get_oauth_clients` (upstream `getOAuthClients`)
   - `get_oauth_consents` (upstream `getOAuthConsents`)
2. Update tests/docs that referenced `list_oauth_*` or legacy `list_o_auth_*`.

**Verify**:

```bash
cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test
cd ../.. && rg -n "list_oauth_clients|list_oauth_consents|list_o_auth" packages/better_auth-oauth-provider
```

Expected: tests pass; no duplicate list/get alias keys.

### Step 6: Canonicalize core duplicate registry keys

In `packages/better_auth/lib/better_auth/core.rb`:

1. Choose canonical keys aligned with upstream registry manifest:
   - keep `list_accounts` (upstream `listUserAccounts` → verify against manifest)
   - remove `list_user_accounts` **or** keep as deprecated alias with same
     endpoint object — prefer **remove** if zero references in repo/tests
   - keep `link_social` (upstream `linkSocialAccount`)
   - remove `link_social_account` alias if unused
2. Grep the repo for removed keys before deleting:

```bash
rg -n "list_user_accounts|link_social_account" packages examples docs-site
```

3. Update any hits to canonical keys.

Repeat the same audit for any other duplicate registry keys surfaced by
`registry_key_mismatch` in the comparison report (one plugin at a time: scim,
sso, open-api, multi-session, organization, admin). For each duplicate:

- keep the upstream-aligned canonical key;
- remove the extra alias if unused;
- if the alias is referenced in tests/docs, migrate references first.

**Verify**:

```bash
bundle exec rake test
ruby scripts/compare-endpoint-api-names.rb
```

Expected: `registry_key_mismatch` count drops; core tests pass.

### Step 7: Add machine-checked parity test

Create `packages/better_auth/test/better_auth/endpoint_registry_parity_test.rb`:

1. Load `reference/upstream-endpoint-registry.json` (skip gracefully with message
   if file missing — but in CI it must exist).
2. Build a full auth instance matching
   `scripts/generate-endpoint-inventory.rb`'s plugin set (reuse a shared helper
   if you extract `EndpointInventory.build_inventory_auth` to
   `scripts/support/inventory_auth.rb` — optional but preferred).
3. For each non-deprecated registry entry whose plugin is loaded in the test auth
   instance:
   - assert Ruby inventory (or live `auth.api` endpoints hash) includes
     `[method, path]`;
   - assert canonical registry key equals `entry["ruby_registry_key"]`;
   - assert `auth.api` responds to the canonical method name.
4. Explicitly skip entries tagged `deprecated: true` except assert Ruby still
   has them until Plan 027 removes `forgetPasswordEmailOTP`.

Model test structure after
`packages/better_auth/test/better_auth/plugins/open_api_test.rb` (Minitest,
real auth instance, no mocks).

**Verify**:

```bash
bundle exec rake test TEST=packages/better_auth/test/better_auth/endpoint_registry_parity_test.rb
```

Expected: test passes.

### Step 8: Refresh reference artifacts and package README tables

1. Regenerate all reference outputs (Step 3 verify commands).
2. Update API method tables in:
   - `packages/better_auth/README.md` (if it lists `auth.api` examples)
   - `packages/better_auth-oauth-provider/README.md`
   - other plugin READMEs that enumerate `auth.api.*` routes
3. Ensure tables show **canonical keys only** and link to
   `reference/ruby-api-naming-policy.md`.

**Verify**:

```bash
bundle exec rake ci
ruby scripts/compare-endpoint-api-names.rb ; test $? -eq 0
```

Expected: CI green; comparison script exits 0.

## Test plan

- New `endpoint_registry_parity_test.rb` covers:
  - canonical email OTP password reset mapping;
  - OAuth `create_oauth_client` ↔ upstream `createOAuthClient`;
  - at least one SCIM, SSO, passkey, and api-key entry from manifest.
- Update any tests broken by OAuth renames or removed duplicate registry keys.
- Regression: existing `open_api_test.rb` operationId assertions remain passing.

## Done criteria

- [ ] `reference/ruby-api-naming-policy.md` documents `oauth` / `oauth2`
  tokens and forbids `_o_auth_` split segments.
- [ ] `reference/upstream-endpoint-registry.json` is generated and checked in.
- [ ] `ruby scripts/compare-endpoint-api-names.rb` exits 0 with zero
  `registry_key_mismatch` for non-deprecated supported routes.
- [ ] All `_o_auth_` / `o_auth2_` endpoint registry keys renamed to `oauth` /
  `oauth2` in oauth-provider and generic-oauth plugins.
- [ ] Duplicate OAuth registry keys `list_oauth_*` removed; README updated.
- [ ] Core duplicate aliases removed or explicitly deprecated per policy.
- [ ] `endpoint_registry_parity_test.rb` passes in `bundle exec rake test`.
- [ ] `bundle exec rake ci` exits 0.
- [ ] `rg -n "_o_auth_|\\bo_auth2_" packages` returns no registry-key hits
  (changelog/historical plan text excluded).
- [ ] Plan 027 deprecated email OTP alias still listed only under deprecated
  section until Plan 027 lands (do not remove it in this plan).
- [ ] `plans/README.md` status row updated.

## STOP conditions

- Upstream target in `reference/upstream-better-auth/VERSION.md` is no longer
  Better Auth v1.6.9 — regenerate manifest against the new pin first.
- A proposed rename would change an HTTP path or JSON wire field name — stop; that
  belongs to Plan 028 or a separate breaking HTTP plan.
- Removing a registry alias finds external gem consumers outside this repo — stop
  and report; add deprecated alias shim instead.
- Comparison script still reports >10 `registry_key_mismatch` after Step 5 — stop
  and attach the report; do not rename blindly.
- Plan 027 already removed `forget_password_email_otp` — skip deprecated assertions
  for that route and note coordination in the PR description.

## Maintenance notes

- When adding a new plugin endpoint, update upstream registry generation (or run
  the script in CI) before merging.
- `@rubyauth/client` should consume path nesting from the registry's
  `upstream_client` column; server Ruby stays on `auth.api.*`.
- Reviewers should reject new duplicate registry keys pointing at the same
  path+method.
- If Plan 028 later renames HTTP paths, regenerate both inventory and registry;
  Ruby registry keys should remain stable unless upstream TS registry keys change.
