# Plan 007: Add server parity tests for context bootstrap, direct API, origin checks, and rate limiting

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report; do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 7920aee..HEAD -- packages/better_auth/lib/better_auth/context.rb packages/better_auth/lib/better_auth/api.rb packages/better_auth/lib/better_auth/router.rb packages/better_auth/lib/better_auth/middleware/origin_check.rb packages/better_auth/lib/better_auth/rate_limiter.rb packages/better_auth/test/better_auth/auth_context_upstream_parity_test.rb packages/better_auth/test/better_auth/api_test.rb packages/better_auth/test/better_auth/router_test.rb packages/better_auth/test/better_auth/request_ip_test.rb packages/better_auth/test/better_auth/url_helpers_test.rb packages/better_auth/test/support/upstream_server_parity.rb`

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: `plans/006-server-parity-inventory-and-test-harness.md`
- **Category**: tests
- **Planned at**: commit `7920aee`, 2026-06-15

## Why this matters

Context bootstrap is one of the largest server-side upstream gaps. Upstream has
dense coverage around context creation, auth initialization, direct API calls,
hook ordering, origin/CSRF protection, trusted proxy headers, dynamic base URL,
and rate limiting. Ruby has important parity tests already, but they are not
complete enough to protect the Rack core while adding plugin and route coverage.

## Current state

Relevant upstream suites and counts:

- `context/create-context.test.ts` has 115 tests covering secret management,
  session config, rate limiting, security checks, social providers, trusted
  origins/providers, generated IDs, password config, logger, database hooks,
  endpoint conflicts, stateless mode, and `hasPlugin`.
- `auth/full.test.ts`, `auth/minimal.test.ts`, and
  `auth/trusted-origins.test.ts` cover auth initialization and trusted origin
  variants.
- `call.test.ts`, `api/index.test.ts`, and `api/to-auth-endpoints.test.ts`
  cover direct call behavior, hooks, disabled paths, custom response codes, and
  APIError headers.
- `api/middlewares/origin-check.test.ts` covers origin checks, Fetch Metadata
  CSRF protection, baseURL inferred from request, and `disableCSRFCheck` versus
  `disableOriginCheck`.
- `api/rate-limiter/rate-limiter.test.ts` covers memory storage, custom
  storage, custom rules, disabled/development behavior, missing client IP
  warning, and IPv6 normalization.

Current Ruby implementation anchors:

```text
packages/better_auth/lib/better_auth/context.rb:149-170
def prepare_for_request!(request)
  runtime = request_runtime
  runtime[:current_session] = nil
  runtime[:new_session] = nil
  if options.dynamic_base_url?
    runtime[:base_url] = resolved_dynamic_base_url(request)
    refresh_cookies!
  elsif options.base_url.to_s.empty?
    runtime[:base_url] = inferred_base_url(request)
  end
  runtime[:trusted_origins] = current_trusted_origins(request)
end

packages/better_auth/lib/better_auth/api.rb:13-45
def call_endpoint(key, input = {})
  context.reset_runtime! if context.respond_to?(:reset_runtime!)
  endpoint = endpoints.fetch(key.to_sym)
  ...
  result = run_endpoint_with_hooks(endpoint, endpoint_context)
  format_result(result, input)
ensure
  context.clear_runtime! if context.respond_to?(:clear_runtime!)
end

packages/better_auth/lib/better_auth/middleware/origin_check.rb:27-66
validate_origin checks cookies/origin/referer and validate_fetch_metadata
blocks cross-site navigations before forcing origin validation.

packages/better_auth/lib/better_auth/rate_limiter.rb:45-81
RateLimiter#call reads context.rate_limit_config, resolves client IP, applies
default/plugin/custom rules, then writes memory/custom/database/secondary storage.
```

Current Ruby tests:

- `auth_context_upstream_parity_test.rb` has 26 tests and already covers dynamic
  base URL, plugin trusted origins, default secret behavior, direct API runtime,
  server-scope blocking, and hook/cookie/error chaining.
- `api_test.rb` has 13 direct API hook/response tests.
- `router_test.rb` has broad Rack routing, body parsing, method, and media type
  coverage.
- `plugins/rate_limit_matrix_test.rb` only covers plugin rate-limit storage
  integration; it is not a general `RateLimiter` parity suite.

## Commands you will need

| Purpose | Command | Expected on success |
| --- | --- | --- |
| Context/API tests | `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/auth_context_upstream_parity_test.rb test/better_auth/api_test.rb` | exit 0 |
| New rate limiter tests | `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/rate_limiter_test.rb` | exit 0 |
| Router/origin tests | `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/router_test.rb test/better_auth/rate_limiter_test.rb` | exit 0 |
| Core tests | `cd packages/better_auth && bundle exec rake test` | exit 0 |
| Lint | `cd packages/better_auth && bundle exec standardrb` | exit 0 |

## Scope

**In scope**:

- `packages/better_auth/test/better_auth/auth_context_upstream_parity_test.rb`
- `packages/better_auth/test/better_auth/api_test.rb`
- `packages/better_auth/test/better_auth/router_test.rb`
- `packages/better_auth/test/better_auth/rate_limiter_test.rb` (create)
- `packages/better_auth/test/better_auth/request_ip_test.rb`
- `packages/better_auth/test/better_auth/url_helpers_test.rb`
- `packages/better_auth/test/support/upstream_server_parity.rb`
- Small source fixes in `packages/better_auth/lib/better_auth/context.rb`,
  `api.rb`, `router.rb`, `middleware/origin_check.rb`, `rate_limiter.rb`, or
  `request_ip.rb` only when a new upstream-parity test exposes a confirmed Ruby
  behavior mismatch.

**Out of scope**:

- Client runtime tests from `client/**`.
- Next.js integration tests.
- Type-only assertions from upstream `types/**` or type-only blocks.
- Adapter dialect behavior not directly needed for `RateLimiter` storage.
- Broad refactoring of duplicated test helpers in existing files.

## Git workflow

- Branch: `test/context-api-origin-rate-limit-parity`
- Commit message style: `test(core): expand context and api parity coverage`
- Do not push or open a PR unless the operator instructed it.

## Steps

### Step 1: Expand context/bootstrap parity tests

Read upstream `context/create-context.test.ts`, `auth/full.test.ts`,
`auth/minimal.test.ts`, and `auth/trusted-origins.test.ts`. Add Ruby tests to
`auth_context_upstream_parity_test.rb` and existing narrow files where they fit.

Cover these server-applicable groups:

- Secret resolution/validation: option secret, env secret aliases, empty secret
  in test, default secret rejection outside test, versioned secrets.
- Session defaults: update age, expires in, fresh age, cookie cache defaults for
  stateless database-less mode.
- Rate limit default config normalization, including disabled/false cases.
- Logger config, app name, telemetry option exposure.
- Database hooks config is stored and callable.
- Plugin initialization order: later plugin defaults must not overwrite explicit
  user options; plugin context additions are exposed.
- Endpoint conflict logging: duplicate plugin endpoints with conflicting methods
  produce a logged error; non-conflicting methods do not.
- `hasPlugin` equivalent: if Ruby exposes this under a different name, test the
  Ruby-specific equivalent and document the adaptation in the test name/comment.
  If no equivalent exists, mark the inventory entry `:ruby_not_applicable` with
  a note.

Prefer one focused test per upstream group, not one giant test.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/auth_context_upstream_parity_test.rb` -> exit 0.

### Step 2: Expand direct API and hook parity tests

Read upstream `call.test.ts`, `api/index.test.ts`, and
`api/to-auth-endpoints.test.ts`. Extend `api_test.rb` and `router_test.rb` with
server-applicable cases:

- Before hooks can mutate `body`, `query`, `params`, `headers`, `path`,
  `request`, and `context` without losing caller-provided values.
- Before hooks can short-circuit with a Rack tuple, an `Endpoint::Result`, or an
  API error response.
- After hooks preserve accumulated `Set-Cookie` headers and can replace the
  body/status in the same order as upstream.
- Disabled paths return not found through Rack and direct API behavior matches
  the Ruby contract.
- Custom response code and custom response headers survive `APIError`.
- Direct API with dynamic base URL requires headers/request unless fallback is
  configured.

If a case is already present, rename nothing unless necessary; add the missing
edge assertion to the existing test.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/api_test.rb test/better_auth/router_test.rb` -> exit 0.

### Step 3: Add origin and Fetch Metadata CSRF parity tests

Read upstream `api/middlewares/origin-check.test.ts`. Add Rack-level tests in
`router_test.rb` or a new focused `middleware/origin_check_test.rb` if it keeps
the file smaller. Cover:

- Missing/null origin is rejected only when validation should run.
- Same-origin and trusted-origin requests with cookies pass.
- Cross-site `navigate` with form or JSON body is blocked.
- Cross-site `cors` with valid trusted origin passes.
- `disable_csrf_check` disables Fetch Metadata and origin checks.
- `disable_origin_check` alone keeps the current backward-compatible warning
  behavior; if upstream has separated semantics that Ruby has intentionally not
  adopted yet, document that adaptation in the test name.
- Path-array `disable_origin_check` skips only matching paths.
- Base URL inferred from request contributes to trusted origins.

Use real Rack envs and `auth.call`; do not mock the middleware.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/router_test.rb` -> exit 0, or include the new origin test file if created.

### Step 4: Add a core RateLimiter parity suite

Create `packages/better_auth/test/better_auth/rate_limiter_test.rb`. Use real
`BetterAuth.auth` plus Rack calls where possible, and direct `RateLimiter#call`
only for storage/unit cases that are hard to trigger through routes.

Cover:

- Memory storage limits within the window and resets after the window. Keep
  timing deterministic by using a tiny window only if the test does not become
  flaky; otherwise inspect stored values or inject a storage object.
- Default special rules for `/sign-in`, `/sign-up`, `/change-password`,
  `/change-email`, `/request-password-reset`, `/send-verification-email`, and
  email-otp paths.
- Custom storage `get`/`set` arity variants accepted by Ruby
  (`ttl:` keyword, positional ttl, update flag).
- Secondary storage JSON string handling.
- Database storage writes `rateLimit` records.
- Custom rule hash, callable rule, wildcard path rule, and `false` disable rule.
- Missing client IP warning logs only once and is skipped when IP tracking is
  disabled.
- IPv4-mapped IPv6 and masked IPv6 addresses produce stable rate-limit keys by
  relying on `RequestIP.client_ip`.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/rate_limiter_test.rb` -> exit 0.

### Step 5: Update the parity inventory

In `packages/better_auth/test/support/upstream_server_parity.rb`, mark these
entries `:covered` or `:partial` with narrowed notes:

- `context/create-context.test.ts`
- `context/init.test.ts`
- `context/init-minimal.test.ts`
- `auth/full.test.ts`
- `auth/minimal.test.ts`
- `auth/trusted-origins.test.ts`
- `call.test.ts`
- `api/index.test.ts`
- `api/to-auth-endpoints.test.ts`
- `api/middlewares/origin-check.test.ts`
- `api/rate-limiter/rate-limiter.test.ts`

If any upstream block is intentionally not portable to Ruby, record it as a
specific note. Do not hide it under a generic "TS only" note unless it is truly
type-only.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/upstream_server_parity_inventory_test.rb` -> exit 0.

### Step 6: Run core verification

Run targeted tests first, then the full core suite and lint.

**Verify**:

- `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/auth_context_upstream_parity_test.rb test/better_auth/api_test.rb test/better_auth/router_test.rb test/better_auth/rate_limiter_test.rb` -> exit 0.
- `cd packages/better_auth && bundle exec rake test` -> exit 0.
- `cd packages/better_auth && bundle exec standardrb` -> exit 0.

## Test plan

Use `auth_context_upstream_parity_test.rb` for context/auth behavior, `api_test.rb`
for direct API/hook behavior, `router_test.rb` for Rack-level origin and request
flow, and new `rate_limiter_test.rb` for core rate limiter behavior. Match the
existing Minitest style: `class ... < Minitest::Test`, `SECRET` constant, real
`BetterAuth.auth`, and direct assertions over actual returned headers/body.

## Done criteria

- [ ] Each upstream suite listed in Step 5 has a corresponding inventory entry
  with an accurate `:covered`, `:partial`, or `:ruby_not_applicable` status.
- [ ] New tests cover all groups listed in Steps 1-4 or contain a precise
  Ruby-specific adaptation note.
- [ ] New tests do not perform real network calls.
- [ ] Targeted test commands exit 0.
- [ ] `cd packages/better_auth && bundle exec rake test` exits 0.
- [ ] `cd packages/better_auth && bundle exec standardrb` exits 0.
- [ ] No package outside `packages/better_auth` is modified.

## STOP conditions

Stop and report back if:

- Plan 006's support files do not exist.
- A server-applicable upstream behavior requires a public API that Ruby does not
  expose and cannot be mapped to a documented Ruby equivalent.
- A new parity test fails and the fix would require broad source refactoring or
  touching files outside this plan's source scope.
- A timing-based rate-limit test is flaky twice.
- A verification command fails twice after a reasonable fix attempt.

## Maintenance notes

This plan protects the core request pipeline. Reviewers should scrutinize any
source change made while adding tests; most of the work should be test coverage,
not implementation churn. Future route and plugin parity plans depend on these
helpers and request semantics being stable.
