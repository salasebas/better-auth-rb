# Plan 009: Add server parity tests for core account, user, password, email verification, sign-in, sign-up, and sign-out routes

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report; do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 7920aee..HEAD -- packages/better_auth/lib/better_auth/routes/account.rb packages/better_auth/lib/better_auth/routes/user.rb packages/better_auth/lib/better_auth/routes/password.rb packages/better_auth/lib/better_auth/routes/email_verification.rb packages/better_auth/lib/better_auth/routes/sign_in.rb packages/better_auth/lib/better_auth/routes/sign_up.rb packages/better_auth/lib/better_auth/routes/sign_out.rb packages/better_auth/test/better_auth/routes packages/better_auth/test/support/upstream_server_parity.rb`

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: `plans/006-server-parity-inventory-and-test-harness.md`, `plans/008-cookies-session-cache-and-session-route-parity.md`
- **Category**: tests
- **Planned at**: commit `7920aee`, 2026-06-15

## Why this matters

Core routes are the public server contract for the Ruby gem. The current Ruby
suite is reasonably broad, but upstream has additional edge cases around account
token refresh, delete-user, change-email, enumeration protection, callback URL
validation, password reset/session revocation, and sign-up/sign-in CSRF/form
behavior. These tests should land before deeper plugin parity because plugins
compose through these routes.

## Current state

Relevant upstream route suites and counts:

- `api/routes/account.test.ts`: 23 tests.
- `api/routes/update-user.test.ts`: 21 tests, including update user,
  delete user, change-email enumeration protection, and change-email without
  `sendVerificationEmail`.
- `api/routes/password.test.ts`: 17 tests, including forgot password, revoke
  sessions on password reset, and verify password.
- `api/routes/email-verification.test.ts`: 17 tests, including secondary
  storage.
- `api/routes/sign-up.test.ts`: 27 tests, including custom fields, enumeration
  protection, CSRF, form data, `sendOnSignUp`, and custom synthetic users.
- `api/routes/sign-in.test.ts`: 13 tests, including URL checks, CSRF,
  additional fields, and form data.
- `api/routes/sign-out.test.ts`: 1 test.

Current Ruby implementation anchors:

```text
packages/better_auth/lib/better_auth/routes/account.rb:5-30
list_accounts returns linked accounts for the current user and maps scope to scopes.

packages/better_auth/lib/better_auth/routes/account.rb:80-131
get_access_token allows server-side userId use, but Rack requests require a session.

packages/better_auth/lib/better_auth/routes/user.rb:141-209
delete_user supports password, verification token flow, and fresh-session fallback.

packages/better_auth/lib/better_auth/routes/user.rb:262-336
change_email handles disabled config, invalid/same email, existing target
enumeration-safe response, update without verification, confirmation, and
verification email flows.

packages/better_auth/lib/better_auth/routes/password.rb:10-74
request_password_reset returns the same message for missing and existing users.

packages/better_auth/lib/better_auth/routes/sign_up.rb:73-118
sign_up_email runs in a transaction, handles existing users, creates user and
credential account, sends verification email, and creates a session unless
auto-sign-in or verification disables it.
```

Current Ruby route tests:

- `routes/account_test.rb`: 24 tests.
- `routes/user_routes_test.rb`: 27 tests.
- `routes/password_test.rb`: 16 tests.
- `routes/email_verification_test.rb`: 13 tests.
- `routes/sign_up_test.rb`: 24 tests.
- `routes/sign_in_test.rb`: 14 tests.
- `routes/sign_out_test.rb`: 2 tests.

## Commands you will need

| Purpose | Command | Expected on success |
| --- | --- | --- |
| Account/user routes | `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/routes/account_test.rb test/better_auth/routes/user_routes_test.rb` | exit 0 |
| Password/email routes | `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/routes/password_test.rb test/better_auth/routes/email_verification_test.rb` | exit 0 |
| Sign-in/up/out routes | `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/routes/sign_up_test.rb test/better_auth/routes/sign_in_test.rb test/better_auth/routes/sign_out_test.rb` | exit 0 |
| Core tests | `cd packages/better_auth && bundle exec rake test` | exit 0 |
| Lint | `cd packages/better_auth && bundle exec standardrb` | exit 0 |

## Scope

**In scope**:

- `packages/better_auth/test/better_auth/routes/account_test.rb`
- `packages/better_auth/test/better_auth/routes/user_routes_test.rb`
- `packages/better_auth/test/better_auth/routes/password_test.rb`
- `packages/better_auth/test/better_auth/routes/email_verification_test.rb`
- `packages/better_auth/test/better_auth/routes/sign_up_test.rb`
- `packages/better_auth/test/better_auth/routes/sign_in_test.rb`
- `packages/better_auth/test/better_auth/routes/sign_out_test.rb`
- `packages/better_auth/test/support/upstream_server_parity.rb`
- Small source fixes in the matching `packages/better_auth/lib/better_auth/routes/*.rb`
  files only when a new parity test exposes a confirmed mismatch.

**Out of scope**:

- Social OAuth provider internals covered by `routes/social_test.rb` unless
  needed to prove `account.rb` token refresh behavior.
- Client package tests and TS type tests.
- External adapter packages.
- Public docs updates unless a test reveals documented Ruby behavior is wrong.

## Git workflow

- Branch: `test/core-route-parity`
- Commit message style: `test(core): expand route parity coverage`
- Do not push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fill account route gaps

Read upstream `api/routes/account.test.ts`. Extend `account_test.rb` with:

- `list_accounts` excludes sensitive token/password fields and maps comma
  scopes to an array.
- `unlink_account` rejects unlinking the last account unless
  `allow_unlinking_all` is enabled, requires fresh sensitive session, and
  handles providerId/accountId matching.
- `get_access_token` through Rack requires session, while direct server call can
  use `userId`.
- `get_access_token` refreshes expired access tokens through provider callback,
  persists refreshed values, and sets account cookie when configured.
- `refresh_token` errors clearly for unsupported provider, missing account,
  missing refresh token, and provider refresh failure.
- `account_info` requires account ownership and uses provider `get_user_info`.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/routes/account_test.rb` -> exit 0.

### Step 2: Fill update-user, delete-user, and change-email gaps

Read upstream `api/routes/update-user.test.ts`. Extend `user_routes_test.rb` with:

- `update_user` rejects non-hash bodies, email changes, empty updates, and
  input:false additional fields.
- `update_user` refreshes the session cookie/cache with updated user fields.
- `delete_user` disabled state returns not found.
- `delete_user` with password validates credential account and wrong password.
- `delete_user` verification email flow creates a token, calls the configured
  sender, and later callback deletes the same authenticated user.
- `delete_user` rejects untrusted callback URLs.
- `change_email` returns an indistinguishable success response when target email
  exists.
- `change_email` works when `update_email_without_verification` is enabled for
  unverified users.
- `change_email` with current verified email and confirmation sender sends old
  email confirmation before new email verification.
- `change_email` without any sender returns the upstream/Ruby error.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/routes/user_routes_test.rb` -> exit 0.

### Step 3: Fill password route gaps

Read upstream `api/routes/password.test.ts`. Extend `password_test.rb` with:

- Missing user password reset does the same observable work shape as existing
  user path: same response message, no user leak, no sender call for missing
  user.
- Reset callback redirects with token for valid token and error for invalid or
  expired token.
- Reset password can create a credential account for users without one.
- `on_password_reset` callback receives user data.
- `revoke_sessions_on_password_reset` deletes existing sessions.
- `verify_password` is server-scope/Rack blocked if currently blocked by router,
  but direct API succeeds with correct password and fails with wrong password.
- Password length max/min errors match existing base codes.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/routes/password_test.rb` -> exit 0.

### Step 4: Fill email verification route gaps

Read upstream `api/routes/email-verification.test.ts`. Extend
`email_verification_test.rb` with:

- Sending verification email for missing user creates dummy/token work without
  leaking existence and returns success.
- Authenticated mismatched email is rejected; already verified email is rejected.
- Verify-email invalid/expired token with callback redirects with error, and
  without callback raises APIError.
- `before_email_verification`, `on_email_verification`, and
  `after_email_verification` callbacks run in order.
- Change-email confirmation and verification token flows update the correct
  email and refresh session/cookie.
- Secondary storage sessions reflect verified email after verification.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/routes/email_verification_test.rb` -> exit 0.

### Step 5: Fill sign-up/sign-in/sign-out route gaps

Read upstream `sign-up.test.ts`, `sign-in.test.ts`, and `sign-out.test.ts`.
Extend the existing files with:

- Sign-up custom fields: required, default, `input: false`, returned false, and
  custom synthetic user with admin/additional fields.
- Sign-up enumeration protection: existing user with required verification
  returns indistinguishable user keys/order and does not create a duplicate.
- Sign-up `send_on_sign_up` default and explicit false behavior.
- Sign-up/sign-in form-encoded bodies reject unsupported media types and accept
  `application/x-www-form-urlencoded`.
- Sign-in invalid callback/error/new-user URLs are rejected.
- Sign-in verification-required path sends verification only when configured.
- Sign-out clears session token, cache/account cookies where enabled, and is
  idempotent without a current session if upstream/Ruby contract says so.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/routes/sign_up_test.rb test/better_auth/routes/sign_in_test.rb test/better_auth/routes/sign_out_test.rb` -> exit 0.

### Step 6: Update the parity inventory

Update `upstream_server_parity.rb` entries for:

- `api/routes/account.test.ts`
- `api/routes/update-user.test.ts`
- `api/routes/password.test.ts`
- `api/routes/email-verification.test.ts`
- `api/routes/sign-up.test.ts`
- `api/routes/sign-in.test.ts`
- `api/routes/sign-out.test.ts`

Mark `:covered` only when all server-applicable describe blocks have Ruby tests
or precise adaptation notes.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/upstream_server_parity_inventory_test.rb` -> exit 0.

### Step 7: Run core verification

**Verify**:

- `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/routes/account_test.rb test/better_auth/routes/user_routes_test.rb test/better_auth/routes/password_test.rb test/better_auth/routes/email_verification_test.rb test/better_auth/routes/sign_up_test.rb test/better_auth/routes/sign_in_test.rb test/better_auth/routes/sign_out_test.rb` -> exit 0.
- `cd packages/better_auth && bundle exec rake test` -> exit 0.
- `cd packages/better_auth && bundle exec standardrb` -> exit 0.

## Test plan

Add tests to existing route files, matching their local helper style unless
Plan 006 helpers are already included in the file. Prefer real auth API calls
and Rack calls over mocks. For provider callbacks, use small lambda providers as
existing social route tests do.

## Done criteria

- [ ] Every upstream route file listed in Step 6 is `:covered` or has precise
  remaining `:partial` notes in the parity inventory.
- [ ] New tests cover account token refresh, delete-user verification,
  change-email enumeration, password reset revocation, email verification
  callbacks, sign-up enumeration, and sign-in CSRF/form behavior.
- [ ] Targeted route tests, full core tests, and StandardRB all exit 0.
- [ ] No package outside `packages/better_auth` is modified.

## STOP conditions

Stop and report back if:

- A test requires browser client behavior or TypeScript-only assertions.
- A route mismatch requires changing public response shape beyond what upstream
  parity clearly demands.
- A source fix touches non-route shared code not listed in Scope.
- A verification command fails twice after a reasonable fix attempt.

## Maintenance notes

Route tests are the contract for framework adapters. Reviewers should check
response bodies, status codes, cookie headers, and enumeration-safe flows
carefully. Keep tests deterministic and avoid relying on exact generated IDs or
token values unless the format is part of the contract.
