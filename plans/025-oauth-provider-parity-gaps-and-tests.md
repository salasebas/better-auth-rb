# Plan 025: OAuth Provider Parity Gaps, JWT Plugin Requirement, and Test Coverage

> **Executor instructions**: Follow this plan step by step. Run every verification
> command and confirm the expected result before moving to the next step. If
> anything in the "STOP conditions" section occurs, stop and report — do not
> improvise. When done, update the status row for this plan in `plans/README.md`
> unless a reviewer told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 2ce7a4a..HEAD -- packages/better_auth packages/better_auth-oauth-provider plans`
>
> If any in-scope file changed since this plan was written, compare the "Current
> state" excerpts against live code before proceeding. A mismatch is a STOP
> condition unless it is only line-number drift and the named symbols still have
> the same behavior.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: plan 019 (DONE — unified oauth-provider surface)
- **Category**: tests, correctness, tech-debt
- **Planned at**: commit `2ce7a4a`, 2026-06-16
- **Issue**: (none)

## Why this matters

Plan 019 unified OAuth/OIDC/MCP under `better_auth-oauth-provider`, but several
upstream behaviors are still missing or only partially covered by tests. The
highest-impact gap is JWT handling: upstream requires the JWT plugin whenever
`disable_jwt_plugin` is false and fails with `jwt_config` instead of silently
signing HS256 tokens. Without parity here, apps think OAuth Provider "works"
without JWT and get the wrong token format at runtime. Secondary gaps — issuer-path
well-known aliases, resource-client verification tests, refresh-token formatting,
MCP handler ergonomics, and thinner register/introspect coverage — reduce
confidence that the Ruby port matches Better Auth v1.6.9.

This plan closes those gaps and raises oauth-provider test count toward upstream
(~261 upstream vs ~216 Ruby today). **Do not modify `docs-site/`** — package
README updates are in scope.

## Current state

### Repository conventions

- Ruby port of Better Auth v1.6.9 (`AGENTS.md`).
- Core: Minitest in `packages/better_auth/test`.
- OAuth Provider gem: Minitest in `packages/better_auth-oauth-provider/test`.
- Style: StandardRB, `# frozen_string_literal: true`, snake_case options.
- Verification:
  - `cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test`
  - `bundle exec standardrb packages/better_auth/lib packages/better_auth-oauth-provider/lib packages/better_auth-oauth-provider/test`
  - Optional core spot-check: `cd packages/better_auth && bundle exec rake test TEST=test/better_auth/plugin_loader_test.rb`

### JWT plugin requirement (parity gap — confirmed)

Upstream (`packages/oauth-provider/src/utils/index.ts`):

```typescript
export const getJwtPlugin = (ctx: AuthContext) => {
  const plugin = ctx.getPlugin("jwt");
  if (!plugin) {
    throw new BetterAuthError("jwt_config");
  }
  return plugin;
};
```

Upstream token/id-token paths call `getJwtPlugin` when `disableJwtPlugin` is
false (`token.ts` ~lines 98, 155–157).

Ruby has the helper but does **not** enforce it in production paths:

- `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider/utils/index.rb:16-20`:

```ruby
def get_jwt_plugin(ctx)
  plugin = ctx.get_plugin("jwt")
  raise Error, "jwt_config" unless plugin
  plugin
end
```

- `packages/better_auth/lib/better_auth/plugins/oauth_protocol.rb:912-915` — soft lookup, no error:

```ruby
def jwt_plugin_options(ctx)
  plugin = ctx.context.options.plugins.find { |entry| entry.id == "jwt" }
  plugin&.options
end
```

- `oauth_protocol.rb:646-651` and `:888-891` — when `use_jwt_plugin` is true but
  JWT plugin is absent, code **falls back to HS256** instead of raising.

- `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider/token.rb` passes
  `use_jwt_plugin: !config[:disable_jwt_plugin]` on every token issue/refresh.

- Test helper `packages/better_auth-oauth-provider/test/support/oauth_provider_flow_helpers.rb:12-21`
  builds auth with **only** `oauth_provider` — no JWT plugin — so most tests rely
  on the silent HS256 fallback today.

- Explicit opt-out is tested: `metadata_utilities_test.rb` (`disable_jwt_plugin: true`),
  `token_test.rb` (`test_id_token_expiration_is_configurable_in_hs256_fallback`).

### Issuer-path well-known aliases (missing)

Ruby registers only:

- `GET /.well-known/oauth-authorization-server` (`metadata.rb:8`)
- `GET /.well-known/openid-configuration` (`metadata.rb:34`)

Upstream init warns that when JWT issuer pathname ≠ `/`, operators must also
expose (comments in `packages/oauth-provider/src/oauth.ts` ~316–352):

- `/.well-known/oauth-authorization-server{issuerPath}` (empty suffix when `/`)
- `{issuerPath}/.well-known/openid-configuration`

Ruby router (`packages/better_auth/lib/better_auth/router.rb:278-294`) matches
exact paths or `:param` segments — no wildcard suffixes. Alias routes must be
registered as additional `Endpoint` entries at init time.

### Resource client / MCP (implemented, undertested)

- `ClientResource.verify_access_token` and `protected_resource_metadata` live in
  `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider/client_resource.rb`.
- Remote introspection path: `remote_introspect` (~lines 97–112).
- MCP helpers in `mcp.rb` — `mcp_handler` requires caller-supplied `verifier:`;
  upstream `mcpHandler` wraps `verifyAccessToken` internally.
- Existing MCP tests (`test/better_auth/oauth_provider/mcp_test.rb`) cover
  `www_authenticate`, error wrapping, and verifier errors — not token verification
  integration.

### Refresh-token formatting and generators (implemented, undertested)

- `encode_refresh_token` / `decode_refresh_token` with optional
  `format_refresh_token: {encrypt:, decrypt:}` — `oauth_protocol.rb:780-802`.
- `generate_opaque_access_token` / `generate_refresh_token` passed through
  `issue_tokens` / `refresh_tokens` (~lines 477, 563).
- No dedicated tests assert encrypt/decrypt round-trip or custom generators.

### Pairwise multi-host error message (minor parity)

Ruby rejects multi-host pairwise redirect URIs
(`oauth_protocol.rb:280-281`) with a short message. Upstream uses OIDC-aligned
wording mentioning `sector_identifier_uri` is not yet supported
(`register.ts` ~151–165). Behavior matches; message should align.

### Test coverage baseline

At plan time:

```bash
cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test
# => 216 runs, 0 failures
```

Upstream oauth-provider: ~261 tests across 18 files. Ruby register tests: 2
(`register_test.rb`). Upstream register: ~19. Ruby introspect: 4. Upstream: ~14
but includes JWT access-token cases Ruby should add.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| OAuth Provider tests | `cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test` | exit 0; run count ≥ 240 |
| Lint | `bundle exec standardrb packages/better_auth/lib/better_auth/plugins/oauth_protocol.rb packages/better_auth-oauth-provider/lib packages/better_auth-oauth-provider/test` | exit 0 |
| Targeted new tests | `cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest test/better_auth/oauth_provider/jwt_plugin_requirement_test.rb` (after creating) | all pass |

## Scope

**In scope**:

- `packages/better_auth/lib/better_auth/plugins/oauth_protocol.rb`
- `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider.rb`
- `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider/metadata.rb`
- `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider/mcp.rb`
- `packages/better_auth-oauth-provider/lib/better_auth/plugins/oauth_provider/client_resource.rb` (tests only unless MCP wrapper needs a thin delegate)
- `packages/better_auth-oauth-provider/test/**` (new and expanded files)
- `packages/better_auth-oauth-provider/test/support/oauth_provider_flow_helpers.rb`
- `packages/better_auth-oauth-provider/README.md` (JWT requirement note only)
- `plans/README.md`

**Out of scope** (do NOT touch):

- `docs-site/**` — explicit maintainer request.
- `reference/upstream-src/**`
- Core plugin removal / re-adding `oidc_provider` or `mcp` (plan 019 territory).
- Implementing full `sector_identifier_uri` support (upstream also marks it unsupported).
- Router wildcard/path-template changes in `packages/better_auth/lib/better_auth/router.rb`.

## Git workflow

- Branch: `feat/oauth-provider-parity-gaps` (or continue on current feature branch).
- Commit style: conventional, e.g. `fix(oauth-provider): require jwt plugin when not disabled`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Enforce JWT plugin when `disable_jwt_plugin` is false

**Goal**: Match upstream — no silent HS256 fallback when JWT mode is expected;
no auto-registration of the JWT plugin.

1. In `oauth_provider_init` (`oauth_provider.rb:183-197`), after existing
   validations, when `!config[:disable_jwt_plugin]`:
   - Resolve JWT plugin from `context.options.plugins` (or `context.get_plugin("jwt")` if available on init context).
   - If missing, raise `BetterAuth::Error, "jwt_config"` (same string upstream uses).
   - Do **not** call `BetterAuth::Plugins.jwt` or mutate the plugin list.

2. In `oauth_protocol.rb`, when `use_jwt_plugin` is true:
   - **`build_jwt_access_token`** (~628-651): if `sign_oauth_jwt` would return nil,
     call `OAuthProvider::Utils.get_jwt_plugin(ctx)` first (or raise `BetterAuth::Error, "jwt_config"`)
     instead of falling through to `JWT.encode(..., HS256)`.
   - **`id_token`** (~862-897): same — when `use_jwt_plugin && ctx`, require JWT plugin;
     do not HS256-fallback unless `use_jwt_plugin` is false.
   - Optionally refactor `sign_oauth_jwt` to call `get_jwt_plugin` internally when
     `use_jwt_plugin` path is taken (keep changes minimal).

3. **`disable_jwt_plugin: true`** must continue to allow HS256 id/access tokens
   (existing tests must still pass).

**Verify**:

```bash
cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest -e '
require "test_helper"
error = assert_raises(BetterAuth::Error) do
  OAuthProviderFlowHelpers.new.extend(OAuthProviderFlowHelpers).build_auth(scopes: ["openid"])
rescue BetterAuth::Error => e
  raise e
end
' 2>/dev/null || true
```

After Step 4 adds the proper test file, use that instead. For now, manual smoke:

```bash
cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test TEST=test/better_auth/oauth_provider/metadata_utilities_test.rb
```

→ `disable_jwt_plugin: true` tests still pass.

### Step 2: Update test helper defaults and add JWT requirement tests

1. Edit `test/support/oauth_provider_flow_helpers.rb#build_auth`:
   - When `options[:disable_jwt_plugin] != true`, prepend
     `BetterAuth::Plugins.jwt(jwks: {key_pair_config: {alg: "EdDSA"}})` to the
     plugins array (before `oauth_provider`).
   - When `disable_jwt_plugin: true`, do **not** add JWT (preserve HS256 tests).

2. Create `test/better_auth/oauth_provider/jwt_plugin_requirement_test.rb`:

```ruby
# frozen_string_literal: true

require_relative "../../test_helper"

class OAuthProviderJwtPluginRequirementTest < Minitest::Test
  include OAuthProviderFlowHelpers

  def test_init_fails_without_jwt_plugin_when_not_disabled
    error = assert_raises(BetterAuth::Error) do
      BetterAuth.auth(
        base_url: "http://localhost:3000",
        secret: SECRET,
        database: :memory,
        email_and_password: {enabled: true},
        plugins: [BetterAuth::Plugins.oauth_provider(scopes: ["openid"])]
      )
    end
    assert_equal "jwt_config", error.message
  end

  def test_disable_jwt_plugin_allows_init_without_jwt
    auth = build_auth(scopes: ["openid"], disable_jwt_plugin: true)
    assert auth.api.get_open_id_config[:issuer]
  end
end
```

3. Grep for tests that construct `BetterAuth.auth` manually without JWT and
   without `disable_jwt_plugin: true`; add JWT plugin or `disable_jwt_plugin: true`
   as appropriate. Known locations from audit:
   - `token_test.rb` JWT-specific test already includes JWT — keep as-is.
   - `metadata_test.rb`, `logout_test.rb`, `oauth_provider_test.rb` — already pass JWT explicitly; ensure still valid.

**Verify**:

```bash
cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test TEST=test/better_auth/oauth_provider/jwt_plugin_requirement_test.rb
```

→ 2 runs, 0 failures.

Then full suite:

```bash
cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test
```

→ 0 failures (run count will drop temporarily if Step 1 broke helpers — fix until green).

### Step 3: Issuer-path well-known alias routes

1. Add helper in `metadata.rb` (or `oauth_provider.rb`) to compute issuer pathname:

```ruby
def oauth_issuer_path(ctx, config)
  return nil if config[:disable_jwt_plugin]
  jwt_plugin = ctx.context.options.plugins.find { |p| p.id == "jwt" }
  issuer = jwt_plugin&.options&.dig(:jwt, :issuer) || OAuthProtocol.issuer(ctx)
  path = URI.parse(issuer.to_s).path
  path == "/" ? nil : path
rescue URI::InvalidURIError
  nil
end
```

2. In `oauth_provider_endpoints`, when `issuer_path` is present and not redundant
   with base-only routes:
   - Register duplicate GET endpoint at
     `/.well-known/oauth-authorization-server#{issuer_path}` → same handler as
     `oauth_server_metadata_endpoint`.
   - Register GET at `#{issuer_path}/.well-known/openid-configuration` → same
     handler as `oauth_openid_metadata_endpoint`.
   - Set `metadata: {hide: true}` on aliases (match existing metadata endpoints).

3. Skip alias registration when `issuer_path` is nil or `"/"`.

4. Create `test/better_auth/oauth_provider/issuer_path_metadata_test.rb`:
   - Auth with JWT plugin `jwt: {issuer: "http://localhost:3000/api/auth/tenant"}`.
   - Assert `auth.api.get_o_auth_server_config` still works on default path.
   - Issue Rack request to alias path via `auth.handler` (see `metadata_test.rb`
     for pattern) and assert 200 + same `issuer` field.
   - Same for OpenID config alias.

**Verify**:

```bash
cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test TEST=test/better_auth/oauth_provider/issuer_path_metadata_test.rb
```

→ all pass.

### Step 4: ClientResource and remote introspection tests

Create `test/better_auth/oauth_provider/client_resource_test.rb`.

Pattern: use `build_auth` (now includes JWT), issue JWT access token with
`resource` audience (copy from `token_test.rb#test_jwt_plugin_signs_jwt_access_tokens_and_introspection_verifies_them`).

Cover:

1. **`protected_resource_metadata`** — returns `resource`, `authorization_servers`,
   merges overrides; raises when `resource` missing.
2. **`verify_access_token` local JWT** — valid token + scopes passes; wrong scope
   raises `FORBIDDEN`; bad signature raises `UNAUTHORIZED` with MCP header when
   mapped.
3. **`verify_access_token` remote introspection** — stub `Net::HTTP` (or use
   `WebMock`-style manual stub if no gem: replace `ClientResource.method(:remote_introspect)`
   with a test double) to return `{"active" => true, "scope" => "read"}`; assert
   payload returned.
4. **`validate_resource_scopes!`** — rejects `openid` scope on resource metadata;
   rejects unknown external scope unless listed in `external_scopes`.

Do not add new gem dependencies for HTTP stubbing — use Minitest stub/minitest/mock
or isolate `remote_introspect` via test subclass/module prepend.

**Verify**:

```bash
cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test TEST=test/better_auth/oauth_provider/client_resource_test.rb
```

→ ≥ 6 runs, 0 failures.

### Step 5: Refresh-token formatting and custom generator tests

Create `test/better_auth/oauth_provider/token_formatting_test.rb`.

1. **`format_refresh_token` round-trip** — configure oauth_provider with:

```ruby
format_refresh_token: {
  encrypt: ->(token, session_id) { "enc:#{token}:#{session_id}" },
  decrypt: ->(value) { _p, token, = value.split(":", 3); token }
}
```

   Issue authorization-code tokens with `offline_access`, refresh, assert new
   access token issued (proves decrypt works on refresh grant).

2. **Custom `generate_refresh_token`** — pass callable returning fixed string;
   assert refresh token prefix/stored hash matches (via introspect active or
   second refresh succeeds).

3. **Custom `generate_opaque_access_token`** — similar smoke for client_credentials
   opaque path (`resource` absent).

Use `OAuthProtocol` methods directly for unit-level encode/decode assertions
where full flow is heavy.

**Verify**:

```bash
cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test TEST=test/better_auth/oauth_provider/token_formatting_test.rb
```

→ ≥ 3 runs, 0 failures.

### Step 6: MCP handler convenience wrapper (upstream `mcpHandler` parity)

In `mcp.rb`, add **without breaking** existing `mcp_handler`:

```ruby
def mcp_handler_with_verifier(verify_options:, resource_metadata_mappings: {}, ctx: nil, scopes: nil, jwks_url: nil, remote_verify: nil, &handler)
  mcp_handler(
    resource: verify_options[:audience] || verify_options["audience"],
    resource_metadata_mappings: resource_metadata_mappings,
    verifier: ->(token) {
      ClientResource.verify_access_token(
        token,
        verify_options: verify_options,
        scopes: scopes,
        jwks_url: jwks_url,
        remote_verify: remote_verify,
        ctx: ctx,
        resource: verify_options[:audience] || verify_options["audience"]
      )
    },
    &handler
  )
end
```

Add tests in `mcp_test.rb`:

- Valid JWT through wrapper calls handler.
- Invalid token returns 401 + `WWW-Authenticate`.

**Verify**:

```bash
cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test TEST=test/better_auth/oauth_provider/mcp_test.rb
```

→ ≥ 5 runs, 0 failures.

### Step 7: Align pairwise multi-host error message

In `oauth_protocol.rb#validate_pairwise_client!`, when `hosts.length > 1`, raise
with upstream-aligned message:

```
pairwise clients with redirect_uris on different hosts require a sector_identifier_uri, which is not yet supported. All redirect_uris must share the same host.
```

Add test in `pairwise_test.rb` or `register_test.rb` asserting message substring
`sector_identifier_uri`.

**Verify**:

```bash
cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test TEST=test/better_auth/oauth_provider/pairwise_test.rb
```

### Step 8: Expand register, introspect, and zod tests

Port **high-value** cases from upstream (read
`reference/upstream-src/1.6.9/.../oauth-provider/src/register.test.ts` and
`introspect.test.ts` if available; otherwise use GitHub raw v1.6.9):

**register_test.rb** — add at least 6 tests:

- Unauthenticated registration when `allow_unauthenticated_client_registration: true`
- Rejects `grant_types` / `response_types` mismatch
- Rejects scopes outside `client_registration_allowed_scopes`
- Public native client defaults (`token_endpoint_auth_method: none`)
- Pairwise without `pairwise_secret` on server → 400
- Client secret expiration in DCR response when configured

**introspect_test.rb** — add at least 3 tests:

- Inactive / unknown token → `{active: false}`
- JWT access token introspection (active, correct `sub`/`scope`) — JWT plugin path
- Expired opaque token → inactive

**types/zod_test.rb** — add at least 2 tests for schemas used in registration
(e.g. `subject_type` enum validation via public API, invalid redirect URI rejected).

Aim for **≥ 30 new test methods** across Steps 2–8 combined.

**Verify**:

```bash
cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test
```

→ 0 failures; run count ≥ 240 (target ≥ 250).

### Step 9: README JWT requirement note

In `packages/better_auth-oauth-provider/README.md`, under Options or a short
"JWT plugin" section, state:

- When `disable_jwt_plugin` is false (default), register `BetterAuth::Plugins.jwt`
  **before** `oauth_provider` in the plugins array.
- Init fails with `jwt_config` if JWT is missing — the plugin is **not** auto-enabled.
- Set `disable_jwt_plugin: true` only for legacy HS256-only deployments.

**Do not edit `docs-site/`.**

**Verify**: `grep -n "jwt_config\|disable_jwt_plugin" packages/better_auth-oauth-provider/README.md` → at least 2 matches.

### Step 10: Final verification and index update

```bash
bundle exec standardrb packages/better_auth/lib/better_auth/plugins/oauth_protocol.rb packages/better_auth-oauth-provider/lib packages/better_auth-oauth-provider/test
cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test
```

Update `plans/README.md` — mark plan 025 DONE with final test count.

## Test plan

| File | Cases |
|------|-------|
| `jwt_plugin_requirement_test.rb` | init fail/success |
| `issuer_path_metadata_test.rb` | alias routes 200 + issuer |
| `client_resource_test.rb` | metadata, local verify, remote introspect, scope guards |
| `token_formatting_test.rb` | format_refresh_token, custom generators |
| `mcp_test.rb` | mcp_handler_with_verifier |
| `register_test.rb`, `introspect_test.rb`, `pairwise_test.rb`, `types/zod_test.rb` | expanded parity |

Structural pattern: `test/better_auth/oauth_provider/token_test.rb` for JWT
token flows; `metadata_test.rb` for Rack `auth.handler` metadata requests.

## Done criteria

ALL must hold:

- [ ] `disable_jwt_plugin: false` without JWT plugin raises `BetterAuth::Error` with message `jwt_config` at init (no auto-enable)
- [ ] `use_jwt_plugin: true` token/id-token paths do not silently HS256-fallback
- [ ] Issuer-path well-known aliases registered and tested when JWT issuer has pathname
- [ ] `client_resource_test.rb` exists with remote introspection coverage
- [ ] `token_formatting_test.rb` covers `format_refresh_token` encrypt/decrypt
- [ ] `mcp_handler_with_verifier` exists and is tested
- [ ] `cd packages/better_auth-oauth-provider && BUNDLE_GEMFILE=Gemfile bundle exec rake test` → 0 failures, ≥ 240 runs
- [ ] `bundle exec standardrb` on scoped paths → exit 0
- [ ] No files under `docs-site/` modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report if:

- Init context does not expose plugin list during `oauth_provider_init` (need different hook point).
- Issuer-path alias registration causes route collisions with existing endpoints.
- Enforcing JWT requirement breaks > 30 tests and helper update pattern is insufficient — report before weakening requirement.
- Upstream issuer-path behavior differs from comments (verify against `oauth.ts` v1.6.9).
- `reference/upstream-src/` is required for test porting but missing — use GitHub raw instead; do not run fetch script unless operator approves.

## Maintenance notes

- Any new oauth-provider test using `build_auth` inherits JWT plugin unless
  `disable_jwt_plugin: true`.
- If JWT plugin options gain dynamic issuer/baseURL, issuer-path alias registration
  may need re-computation — watch JWT plugin changes.
- Reviewers should confirm no HS256 fallback remains on JWT-intended paths and that
  error message `jwt_config` matches upstream for client/documentation parity.
- Full `sector_identifier_uri` support is deferred (upstream also rejects today).
