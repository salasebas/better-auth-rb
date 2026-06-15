# Plan 011: Complete server parity tests for email-otp, magic-link, and one-time-token plugins

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report; do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 7920aee..HEAD -- packages/better_auth/lib/better_auth/plugins/email_otp.rb packages/better_auth/lib/better_auth/plugins/magic_link.rb packages/better_auth/lib/better_auth/plugins/one_time_token.rb packages/better_auth/test/better_auth/plugins/email_otp_test.rb packages/better_auth/test/better_auth/plugins/magic_link_test.rb packages/better_auth/test/better_auth/plugins/one_time_token_test.rb packages/better_auth/test/support/upstream_server_parity.rb`

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: `plans/006-server-parity-inventory-and-test-harness.md`, `plans/008-cookies-session-cache-and-session-route-parity.md`, `plans/009-core-route-parity-account-user-password-email-signin-signup.md`
- **Category**: tests
- **Planned at**: commit `7920aee`, 2026-06-15

## Why this matters

These plugins sit directly on top of core sign-in, email verification, password
reset, and session-cookie behavior. Upstream has 73 email-otp tests, 18
magic-link tests, and 13 one-time-token tests. Ruby has coverage for the main
flows, but the remaining edge cases are exactly where regressions are likely:
storage strategies, attempts, rate limiting, origin validation, override hooks,
and one-time token cookie/header options.

## Current state

Relevant upstream suites:

- `plugins/email-otp/email-otp.test.ts`: email OTP sign-in/verification,
  change email request/change flows, verify-current-email, email-otp-verify,
  custom rate-limit storage, custom generate/store OTP, override default email
  verification, sign-up with additional fields, race condition protection, and
  resend strategy.
- `plugins/magic-link/magic-link.test.ts`: sign-in link creation, verify,
  origin validation, storeToken, and allowedAttempts.
- `plugins/one-time-token/one-time-token.test.ts`: generate/verify, hashed and
  custom hasher storage, disableClientRequest, disableSetSessionCookie, and
  setOttHeaderOnNewSession.

Current Ruby implementation anchors:

```text
packages/better_auth/lib/better_auth/plugins/email_otp.rb:13-36
email_otp registers send/create/get/check/verify/sign-in/password-reset/change-email endpoints.

packages/better_auth/lib/better_auth/plugins/email_otp.rb:51-77
override_default_email_verification replaces email_verification.send_verification_email
with an OTP-backed implementation.

packages/better_auth/lib/better_auth/plugins/magic_link.rb:30-75
sign_in_magic_link validates email, stores a verification value, builds a link,
and calls send_magic_link.

packages/better_auth/lib/better_auth/plugins/magic_link.rb:78-188
magic_link_verify validates callbacks, checks token/expiry/attempts, creates or
finds a user, sets session cookie, and returns JSON or redirect.

packages/better_auth/lib/better_auth/plugins/one_time_token.rb:31-100
one-time token generate/verify endpoints create verification values, consume on
verify, restore session, and optionally suppress session cookie.
```

Current Ruby tests:

- `email_otp_test.rb`: 21 tests.
- `magic_link_test.rb`: 15 tests.
- `one_time_token_test.rb`: 7 tests.

## Commands you will need

| Purpose | Command | Expected on success |
| --- | --- | --- |
| Email OTP tests | `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/email_otp_test.rb` | exit 0 |
| Magic link tests | `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/magic_link_test.rb` | exit 0 |
| One-time token tests | `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/one_time_token_test.rb` | exit 0 |
| Core tests | `cd packages/better_auth && bundle exec rake test` | exit 0 |
| Lint | `cd packages/better_auth && bundle exec standardrb` | exit 0 |

## Scope

**In scope**:

- `packages/better_auth/test/better_auth/plugins/email_otp_test.rb`
- `packages/better_auth/test/better_auth/plugins/magic_link_test.rb`
- `packages/better_auth/test/better_auth/plugins/one_time_token_test.rb`
- `packages/better_auth/test/support/upstream_server_parity.rb`
- Small source fixes in `email_otp.rb`, `magic_link.rb`, or
  `one_time_token.rb` only when a new parity test exposes a confirmed mismatch.

**Out of scope**:

- Email delivery integrations; use lambdas/arrays to observe callbacks.
- Browser client tests.
- Real network calls.
- Rewriting core email verification or session routes unless Plan 009 already
  exposed the needed behavior.

## Git workflow

- Branch: `test/otp-magic-link-token-parity`
- Commit message style: `test(core): expand otp and magic link parity coverage`
- Do not push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fill email-otp base flow and storage gaps

Read upstream `plugins/email-otp/email-otp.test.ts`. Extend
`email_otp_test.rb` with:

- `send_verification_otp` validates email/type and rejects `change-email`
  through the public send endpoint if Ruby follows that implementation.
- `create_verification_otp`, `get_verification_otp`, and
  `check_verification_otp` behavior for plain, hashed, encrypted, custom
  encryptor, and custom hasher storage.
- `allowed_attempts` increments on failed checks, rejects too many attempts, and
  does not consume OTP when `check` is non-consuming.
- Expired OTP returns the expected error and deletes/keeps storage according to
  upstream/Ruby contract.
- Custom `generate_otp` receives email/type/context if Ruby supports context;
  if arity differs, document the Ruby adaptation in the test name.
- Custom `store_otp` / `storeOTP` option names if Ruby supports both snake and
  camel case.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/email_otp_test.rb` -> exit 0.

### Step 2: Fill email-otp sign-in, verification, change-email, and reset gaps

Add tests for:

- Sign-in creates a user when allowed, rejects missing user when sign-up is
  disabled, sets session cookie, and returns token/user.
- `verify_email_otp` marks user verified, runs email verification callbacks,
  optionally auto-signs-in, and refreshes current session when present.
- Password reset request/reset OTP flow works and revokes sessions when
  configured.
- Change-email request/change flows, including verify-current-email enabled,
  current email mismatch, target email exists enumeration-safe response, and
  no sender configured error.
- `override_default_email_verification` integrates with core sign-up/send
  verification routes.
- Sign-up with additional fields via email-otp stores and returns allowed fields.
- Race condition protection: a consumed OTP cannot be used twice.
- Resend strategy behavior if Ruby implements it; otherwise mark exact partial
  note in inventory.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/email_otp_test.rb` -> exit 0.

### Step 3: Fill magic-link gaps

Read upstream `plugins/magic-link/magic-link.test.ts`. Extend
`magic_link_test.rb` with:

- `send_magic_link` receives email, URL, token, metadata, and context.
- Callback URL, error callback URL, and new-user callback URL are validated for
  relative and trusted absolute URLs.
- Existing user verify returns/redirects correctly and marks email verified if
  needed.
- New user verify respects `disable_sign_up`, uses provided name, and redirects
  to new-user callback.
- Invalid, expired, malformed JSON, missing token, and attempts-exceeded paths
  redirect with expected error query.
- `store_token` plain, hashed, and custom hasher modes.
- `allowed_attempts` default one, numeric, and infinite/no-limit equivalents if
  Ruby supports them.
- Rate limit rule for `/sign-in/magic-link` and `/magic-link/verify` uses
  plugin window/max.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/magic_link_test.rb` -> exit 0.

### Step 4: Fill one-time-token gaps

Read upstream `plugins/one-time-token/one-time-token.test.ts`. Extend
`one_time_token_test.rb` with:

- Generate requires current session, stores the current session token, and
  returns a token.
- Verify consumes the token exactly once.
- Expired token, missing verification, missing session, and expired session
  errors.
- `store_token` plain, hashed, and custom hasher.
- `disable_client_request` rejects Rack/client request but permits direct
  server API call if that is Ruby's contract.
- `disable_set_session_cookie` verifies session without setting session cookie.
- `set_ott_header_on_new_session` adds `set-ott` and exposes it through
  `access-control-expose-headers` on sign-up/sign-in responses.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/one_time_token_test.rb` -> exit 0.

### Step 5: Update the parity inventory

Update entries for:

- `plugins/email-otp/email-otp.test.ts`
- `plugins/magic-link/magic-link.test.ts`
- `plugins/one-time-token/one-time-token.test.ts`

Mark `:covered` only when all server-applicable describe blocks above have Ruby
coverage. Record exact `:partial` notes for unimplemented options such as resend
strategy if they remain missing.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/upstream_server_parity_inventory_test.rb` -> exit 0.

### Step 6: Run core verification

**Verify**:

- `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/email_otp_test.rb test/better_auth/plugins/magic_link_test.rb test/better_auth/plugins/one_time_token_test.rb` -> exit 0.
- `cd packages/better_auth && bundle exec rake test` -> exit 0.
- `cd packages/better_auth && bundle exec standardrb` -> exit 0.

## Test plan

Use arrays to capture outgoing emails/links/OTPs. Use actual `auth.api` calls
for direct server behavior and Rack calls only for request-only/client request
distinctions. Do not mock internal adapter calls unless a race/consume path
cannot be observed through public behavior.

## Done criteria

- [ ] Email-otp, magic-link, and one-time-token upstream server describe blocks
  are covered or precisely marked partial.
- [ ] New tests cover storage modes, attempts, expiration, callbacks, rate
  limits, origin/callback validation, and cookie/header options.
- [ ] Targeted plugin tests, full core tests, and StandardRB all exit 0.

## STOP conditions

Stop and report back if:

- An upstream option is absent in Ruby and adding it would be feature work
  rather than test coverage.
- A test requires real email or network delivery.
- A source fix touches core routes outside the files listed in Scope.
- A verification command fails twice after a reasonable fix attempt.

## Maintenance notes

These plugins are sensitive to replay and enumeration bugs. Reviewers should
pay close attention to tests that prove tokens are consumed, attempts are
counted, and responses do not leak whether a user exists.
