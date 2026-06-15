# Plan 008: Add server parity tests for cookies, session cache, and session routes

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report; do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 7920aee..HEAD -- packages/better_auth/lib/better_auth/cookies.rb packages/better_auth/lib/better_auth/session_store.rb packages/better_auth/lib/better_auth/session.rb packages/better_auth/lib/better_auth/routes/session.rb packages/better_auth/test/better_auth/cookies_test.rb packages/better_auth/test/better_auth/session_test.rb packages/better_auth/test/better_auth/routes/session_routes_test.rb packages/better_auth/test/support/upstream_server_parity.rb`

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: `plans/006-server-parity-inventory-and-test-harness.md`
- **Category**: tests
- **Planned at**: commit `7920aee`, 2026-06-15

## Why this matters

Cookies and session refresh/cache semantics are a high-risk auth surface:
session tokens, `Set-Cookie` attributes, cache invalidation, chunking, secret
rotation, and deferred session refresh all live here. Upstream has 54 cookie
tests and 56 session API tests; Ruby has useful coverage, but it is still much
thinner than the server behavior it implements.

## Current state

Relevant upstream suites:

- `cookies/cookies.test.ts` describe blocks include cookie defaults,
  production environment, cross-subdomain cookies, cookie configuration,
  set-cookie parsing utilities, secure prefix stripping, `getSessionCookie`,
  cookie cache field filtering, chunking, parsing, and expiring cookies.
- `api/routes/session-api.test.ts` describe blocks include base session routes,
  session storage, cookie cache, JWT/JWE cache strategies, refresh cache,
  cache versioning, `deferSessionRefresh`, date field consistency, and
  `updateSession`.

Current Ruby implementation anchors:

```text
packages/better_auth/lib/better_auth/cookies.rb:18-24
def get_cookies(options)
  {
    session_token: create_cookie(options, "session_token", max_age: options.session[:expires_in] || 60 * 60 * 24 * 7),
    session_data: create_cookie(options, "session_data", max_age: options.session.dig(:cookie_cache, :max_age) || 60 * 5),
    account_data: create_cookie(options, "account_data", max_age: options.session.dig(:cookie_cache, :max_age) || 60 * 5),
    dont_remember: create_cookie(options, "dont_remember")
  }
end

packages/better_auth/lib/better_auth/cookies.rb:153-176
get_cookie_cache reads a session_data cookie, supports explicit secure/full
cookie names, decodes compact/JWT/JWE payloads, and rejects version mismatch.

packages/better_auth/lib/better_auth/session_store.rb:48-58
SessionStore.get_chunked_cookie returns direct cookie value first, then joins
numbered chunks.

packages/better_auth/lib/better_auth/routes/session.rb:5-40
get_session accepts GET and POST, enforces defer_session_refresh for POST,
returns nil without session, and adds needsRefresh for deferred GET.
```

Current Ruby tests:

- `cookies_test.rb` has 11 tests for defaults, advanced overrides, signed cookie
  round-trip, parse cookies, cache strategies, rotation, returned:false
  filtering, and chunking.
- `routes/session_routes_test.rb` has 29 tests for get/list/update/revoke
  sessions, cookie cache, deferred refresh, secondary storage, and date fields.
- `session_test.rb` has 6 lower-level session lookup/refresh tests.

## Commands you will need

| Purpose | Command | Expected on success |
| --- | --- | --- |
| Cookie tests | `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/cookies_test.rb` | exit 0 |
| Session route tests | `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/routes/session_routes_test.rb test/better_auth/session_test.rb` | exit 0 |
| Inventory | `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/upstream_server_parity_inventory_test.rb` | exit 0 |
| Core tests | `cd packages/better_auth && bundle exec rake test` | exit 0 |
| Lint | `cd packages/better_auth && bundle exec standardrb` | exit 0 |

## Scope

**In scope**:

- `packages/better_auth/test/better_auth/cookies_test.rb`
- `packages/better_auth/test/better_auth/session_test.rb`
- `packages/better_auth/test/better_auth/routes/session_routes_test.rb`
- `packages/better_auth/test/support/upstream_server_parity.rb`
- Small source fixes in `cookies.rb`, `session_store.rb`, `session.rb`, or
  `routes/session.rb` only when a new parity test exposes a confirmed mismatch.

**Out of scope**:

- Browser client session refresh tests from `client/session-refresh.test.ts`.
- Framework cookie integration in Rails/Sinatra/Hanami/Grape/Roda packages.
- New dependencies for cookie parsing.
- Large refactors of `Cookies` or `SessionStore`.

## Git workflow

- Branch: `test/cookies-session-parity`
- Commit message style: `test(core): expand cookie and session parity coverage`
- Do not push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fill cookie definition and parsing gaps

Read upstream `cookies/cookies.test.ts` through the cookie configuration,
`parseSetCookieHeader`, `stripSecureCookiePrefix`, `parse cookies`, and
`expireCookie` describe blocks. Extend `cookies_test.rb` with server-applicable
Ruby cases:

- Production environment secure-cookie default for `RACK_ENV`, `RAILS_ENV`, and
  `APP_ENV`; ensure env is restored after each assertion.
- `use_secure_cookies: false` overrides production/https defaults.
- Cross-subdomain cookies derive domain from static base URL and raise without
  base URL unless dynamic base URL is configured.
- `default_cookie_attributes` merge before per-cookie overrides.
- Secure and host prefixes are stripped by `strip_secure_cookie_prefix`.
- `parse_cookies` handles empty headers, values containing `=`, duplicate keys
  by last write, percent decoding, and invalid percent sequences.
- `expire_cookie` emits `Max-Age=0` and preserves path/domain attributes.

If upstream's `parseSetCookieHeader` has no exact Ruby public equivalent, cover
the closest Ruby behavior: `Endpoint::Result` multiline `set-cookie` handling
and `Endpoint::Context#set_cookie` output. Mark the inventory note as
`Ruby uses Endpoint set-cookie helpers instead of a standalone parseSetCookieHeader utility`.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/cookies_test.rb` -> exit 0.

### Step 2: Fill cookie cache and chunking gaps

Continue in `cookies_test.rb`. Add tests for:

- Compact cache rejects expired payloads and tampered HMAC payloads.
- JWT and JWE cache reject wrong secrets.
- `cookie_full_name` and `is_secure` options in `get_cookie_cache`.
- Version callback support: configured callable receives session and user and
  mismatch returns nil.
- Chunk cleanup: replacing a previously chunked cache with a small value emits
  cleanup cookies for old chunks.
- Chunk ordering handles `.0`, `.1`, `.10` numerically.
- Account cookie chunking mirrors session data chunking.

Use direct `Endpoint::Context` where possible. Avoid sleeping for expiration;
encode payloads with an already-expired timestamp or use very small max age only
when deterministic.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/cookies_test.rb` -> exit 0.

### Step 3: Expand session route parity tests

Read upstream `api/routes/session-api.test.ts`. Extend
`routes/session_routes_test.rb` and `session_test.rb` with:

- `get_session` returns nil and clears cookies for missing DB session, expired
  DB session, and malformed/tampered signed session cookie.
- `get_session` prefers authoritative DB when `disableCookieCache=true`, and
  uses cache otherwise for compact/JWT/JWE strategies.
- `disableRefresh=true` suppresses DB session refresh and `Set-Cookie`.
- `dont_remember` session has no max-age on session token and affects refresh.
- Secondary storage session behavior for `preserveSessionInDatabase: false` and
  `true` equivalents if Ruby exposes those options; if Ruby's option names
  differ, use the Ruby names and document in test names.
- `defer_session_refresh`: GET reports `needsRefresh`, POST refreshes, POST is
  rejected when defer is disabled.
- Date field consistency: API responses expose parseable string dates, while
  internal adapter can continue using `Time`.
- `update_session` accepts only declared additional session fields, rejects
  body arrays/non-hashes, refreshes cookie cache, and does not permit core
  immutable fields like token/userId unless explicitly declared.

Prefer direct `auth.api` calls for session internals and Rack calls only when
cookie/header behavior matters.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/routes/session_routes_test.rb test/better_auth/session_test.rb` -> exit 0.

### Step 4: Update the parity inventory

In `upstream_server_parity.rb`, update:

- `cookies/cookies.test.ts`
- `api/routes/session-api.test.ts`

Move to `:covered` only if every server-applicable upstream describe block has
at least one Ruby parity test or a precise Ruby-specific not-applicable note.
Otherwise leave `:partial` and list the remaining section names.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/upstream_server_parity_inventory_test.rb` -> exit 0.

### Step 5: Run core verification

**Verify**:

- `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/cookies_test.rb test/better_auth/session_test.rb test/better_auth/routes/session_routes_test.rb` -> exit 0.
- `cd packages/better_auth && bundle exec rake test` -> exit 0.
- `cd packages/better_auth && bundle exec standardrb` -> exit 0.

## Test plan

Model new low-level cookie tests after `cookies_test.rb` and route behavior
tests after `routes/session_routes_test.rb`. Keep helpers local only when the
logic is specific to cookie/session assertions; otherwise use the shared helpers
from Plan 006.

## Done criteria

- [ ] Cookie tests cover every server-applicable describe block from
  `cookies/cookies.test.ts` or document a Ruby-specific equivalent.
- [ ] Session route tests cover every server-applicable describe block from
  `api/routes/session-api.test.ts`.
- [ ] No test uses real time sleeps longer than 0.05 seconds.
- [ ] Inventory entries are updated accurately.
- [ ] Targeted tests, full core tests, and StandardRB all exit 0.

## STOP conditions

Stop and report back if:

- A required test would need a public cookie utility Ruby does not expose and no
  equivalent behavior can be asserted through `Endpoint`/`SessionStore`.
- A parity fix requires changing cookie serialization format for existing users.
- A new test is flaky because of time-based expiration.
- A source fix touches files outside the in-scope list.
- A verification command fails twice after a reasonable fix attempt.

## Maintenance notes

Cookie behavior is compatibility-sensitive. Reviewers should check multiline
`Set-Cookie` assertions, secure prefix behavior, and secret-rotation tests
closely. Future plugin tests will rely on this plan's session cache semantics.
