# Plan 012: Complete remaining server plugin parity for anonymous, multi-session, bearer, captcha, HIBP, SIWE, last-login-method, custom-session, and additional-fields

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report; do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 7920aee..HEAD -- packages/better_auth/lib/better_auth/plugins/anonymous.rb packages/better_auth/lib/better_auth/plugins/multi_session.rb packages/better_auth/lib/better_auth/plugins/bearer.rb packages/better_auth/lib/better_auth/plugins/captcha.rb packages/better_auth/lib/better_auth/plugins/have_i_been_pwned.rb packages/better_auth/lib/better_auth/plugins/siwe.rb packages/better_auth/lib/better_auth/plugins/last_login_method.rb packages/better_auth/lib/better_auth/plugins/custom_session.rb packages/better_auth/lib/better_auth/plugins/additional_fields.rb packages/better_auth/test/better_auth/plugins packages/better_auth/test/support/upstream_server_parity.rb`

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: MED
- **Depends on**: `plans/006-server-parity-inventory-and-test-harness.md`, `plans/008-cookies-session-cache-and-session-route-parity.md`, `plans/009-core-route-parity-account-user-password-email-signin-signup.md`, `plans/011-email-otp-magic-link-one-time-token-parity.md`
- **Category**: tests
- **Planned at**: commit `7920aee`, 2026-06-15

## Why this matters

After organization and OTP/magic-link, the remaining server plugin gap is spread
across smaller hook-heavy plugins. These plugins often mutate core route
behavior indirectly through before/after hooks, cookies, headers, password
hashing, or schema additions. Full server parity needs real integration tests
for those interactions, not only plugin factory assertions.

## Current state

Relevant upstream suites:

- `plugins/anonymous/anon.test.ts`: 12 tests plus cleanup safeguards.
- `plugins/multi-session/multi-session.test.ts`: 9 tests.
- `plugins/bearer/bearer.test.ts`: 5 tests.
- `plugins/captcha/captcha.test.ts`: 17 tests across Cloudflare Turnstile,
  Google reCAPTCHA, hCaptcha, and CaptchaFox.
- `plugins/haveibeenpwned/haveibeenpwned.test.ts`: 4 tests plus disabled mode.
- `plugins/siwe/siwe.test.ts`: 17 tests.
- `plugins/last-login-method/last-login-method.test.ts`: 15 tests plus
  `custom-prefix.test.ts` with 6 tests.
- `plugins/custom-session/custom-session.test.ts`: 11 tests.
- `plugins/additional-fields/additional-fields.test.ts`: 10 tests.

Current Ruby implementation anchors:

```text
anonymous.rb:19-39 registers sign-in/delete endpoints plus after hook that
links/deletes anonymous users after real sign-in routes.

multi_session.rb:11-35 registers list/set-active/revoke endpoints plus hooks
that maintain per-session signed multi cookies.

bearer.rb:11-31 registers before/after hooks that map Authorization Bearer to
session cookie and expose set-auth-token.

captcha.rb:35-45 registers an on_request plugin that verifies configured
endpoints before route execution.

have_i_been_pwned.rb:21-31 wraps password hashing during plugin init.

siwe.rb:12-23 registers nonce and verify endpoints plus wallet schema.

last_login_method.rb:7-26 registers an after hook and optional schema field.

custom_session.rb:7-63 overrides get-session and can mutate multi-session list.

additional_fields.rb:7-27 maps user/session additional fields into plugin schema
and options.
```

Current Ruby tests already exist for all these plugins, but several are compact:

- `anonymous_test.rb`: 14 tests.
- `multi_session_test.rb`: 6 tests.
- `bearer_test.rb`: 11 tests.
- `captcha_test.rb`: 12 tests.
- `have_i_been_pwned_test.rb`: 7 tests.
- `siwe_test.rb`: 9 tests.
- `last_login_method_test.rb`: 10 tests.
- `custom_session_test.rb`: 6 tests.
- `additional_fields_test.rb`: 3 tests.

## Commands you will need

| Purpose | Command | Expected on success |
| --- | --- | --- |
| Long-tail plugin tests | `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/anonymous_test.rb test/better_auth/plugins/multi_session_test.rb test/better_auth/plugins/bearer_test.rb test/better_auth/plugins/captcha_test.rb test/better_auth/plugins/have_i_been_pwned_test.rb test/better_auth/plugins/siwe_test.rb test/better_auth/plugins/last_login_method_test.rb test/better_auth/plugins/custom_session_test.rb test/better_auth/plugins/additional_fields_test.rb` | exit 0 |
| Inventory | `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/upstream_server_parity_inventory_test.rb` | exit 0 |
| Core tests | `cd packages/better_auth && bundle exec rake test` | exit 0 |
| Lint | `cd packages/better_auth && bundle exec standardrb` | exit 0 |

## Scope

**In scope**:

- Existing Ruby test files for the plugins listed in this plan.
- `packages/better_auth/test/support/upstream_server_parity.rb`
- Small source fixes in the matching plugin implementation files only when a
  new parity test exposes a confirmed mismatch.

**Out of scope**:

- Plugins already called "reasonably close" unless their upstream server suite
  remains classified partial by Plan 006: admin, jwt, two-factor, phone-number,
  device-authorization, generic-oauth, open-api, username, oauth-proxy.
- External package plugin gems: api-key, passkey, scim, stripe, sso.
- Real network calls to CAPTCHA or HIBP services.
- Browser/client API tests.

## Git workflow

- Branch: `test/long-tail-plugin-parity`
- Commit message style: `test(core): expand remaining server plugin parity`
- Do not push or open a PR unless the operator instructed it.

## Steps

### Step 1: Complete anonymous plugin coverage

Read upstream `plugins/anonymous/anon.test.ts`. Extend `anonymous_test.rb` with:

- Custom email/name generators receive expected context where Ruby supports it.
- Invalid generated email variants are rejected.
- Anonymous user cannot sign in anonymously twice.
- Delete anonymous user disabled, non-anonymous user, and failed delete cases.
- Linking anonymous to email/password, magic-link, email-otp, SIWE, and social
  routes where implemented; prior anonymous user is deleted unless disabled.
- Cleanup safeguards: do not delete if new session is the same user, still
  anonymous, missing session cookie, or set-cookie only contains the session
  cookie name as a substring.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/anonymous_test.rb` -> exit 0.

### Step 2: Complete multi-session and bearer coverage

Read upstream `multi-session.test.ts` and `bearer.test.ts`. Extend:

- `multi_session_test.rb`:
  - list device sessions deduplicates by user and ignores expired sessions.
  - set active rejects missing, unsigned, expired, and unknown session tokens.
  - revoke active chooses next valid session or clears session cookie.
  - maximum_sessions behavior, same-user replacement, secure-prefix cookie names,
    and sign-out clearing all multi-session cookies.
- `bearer_test.rb`:
  - raw token signing, signed token acceptance, malformed signature rejection.
  - `require_signature` rejects raw bearer token.
  - Authorization header casing and URL-encoded signed token handling.
  - Existing cookie is preserved/merged when bearer auth applies.
  - `set-auth-token` is exposed only for non-expired session cookies and merges
    existing `access-control-expose-headers`.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/multi_session_test.rb test/better_auth/plugins/bearer_test.rb` -> exit 0.

### Step 3: Complete captcha and have-i-been-pwned coverage

Read upstream `captcha.test.ts` and `haveibeenpwned.test.ts`. Extend:

- `captcha_test.rb`:
  - Default endpoints and custom endpoints.
  - Missing secret key returns the Ruby internal error path.
  - Missing response returns 400 with external code.
  - Provider payloads for Cloudflare JSON, Google form, hCaptcha sitekey,
    CaptchaFox remoteIp.
  - Google score threshold accepts/rejects.
  - Verifier callback can return string/symbol-keyed hash and is normalized.
  - HTTP failure and invalid JSON become service unavailable/unknown error.
  - No real network; use verifier lambdas or stub `HTTPClient.request` with
    Minitest stub.
- `have_i_been_pwned_test.rb`:
  - Default protected paths: sign-up, change-password, reset-password.
  - Disabled mode skips lookup.
  - Custom paths and custom compromised message.
  - Range lookup prefix/suffix comparison is case-insensitive and sends no full
    password/hash to the lookup callback.
  - Lookup failure returns internal error.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/captcha_test.rb test/better_auth/plugins/have_i_been_pwned_test.rb` -> exit 0.

### Step 4: Complete SIWE coverage

Read upstream `siwe.test.ts`. Extend `siwe_test.rb` with:

- Nonce endpoint validates wallet and chain ID and stores nonce per
  wallet/chain.
- Missing `get_nonce` callback returns internal error.
- Verify requires nonce, rejects expired/missing nonce, invalid signature, and
  missing `verify_message` callback.
- Anonymous true creates generated email/user; anonymous false requires valid
  email.
- Existing wallet signs in existing user; new wallet creates walletAddress row
  and account row.
- Chain ID default and custom chain ID.
- Wallet checksum normalization and invalid wallet errors.
- Custom schema mappings for wallet address table/fields.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/siwe_test.rb` -> exit 0.

### Step 5: Complete last-login-method, custom-session, and additional-fields coverage

Read upstream `last-login-method/*.test.ts`, `custom-session.test.ts`, and
`additional-fields.test.ts`. Extend:

- `last_login_method_test.rb`:
  - Email sign-up and sign-in set cookie and optional DB field.
  - Magic-link, SIWE, social callback, generic OAuth callback, passkey/phone
    path mapping if Ruby exposes those routes in core.
  - Failed auth paths do not set cookie.
  - Custom resolver wins over default resolver.
  - Custom cookie name, custom cookie prefix, max_age, http_only false, and
    advanced cookie attributes.
- `custom_session_test.rb`:
  - Resolver receives parsed/filtered session and context.
  - Nil session does not call resolver.
  - Cookie max-age values are preserved.
  - `disableCookieCache` and `disableRefresh` query flags flow through.
  - Multi-session list mutation only when configured.
- `additional_fields_test.rb`:
  - User and session required/default/input:false/returned:false behavior.
  - Runtime update-user/update-session validation.
  - Sign-up with additional fields through core and plugin-composed routes.
  - Secondary storage/default session fields.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/last_login_method_test.rb test/better_auth/plugins/custom_session_test.rb test/better_auth/plugins/additional_fields_test.rb` -> exit 0.

### Step 6: Update the parity inventory

Update entries for all upstream files listed in "Current state". Mark each
`covered`, `partial`, or `ruby_not_applicable` with exact notes. Do not mark a
suite covered if an upstream server option is unimplemented; use `partial`.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/upstream_server_parity_inventory_test.rb` -> exit 0.

### Step 7: Run core verification

**Verify**:

- Run the long-tail plugin test command from the commands table -> exit 0.
- `cd packages/better_auth && bundle exec rake test` -> exit 0.
- `cd packages/better_auth && bundle exec standardrb` -> exit 0.

## Test plan

Keep tests in the existing plugin-specific files. Use real route/API calls for
hook interactions. For external services, use explicit lambda verifiers or
Minitest stubs around `HTTPClient.request` and restore automatically via block
form.

## Done criteria

- [ ] All upstream server suites listed in this plan are `covered` or have
  precise `partial` notes.
- [ ] No new test performs real network I/O.
- [ ] Hook-heavy plugins are tested through observable route/session/cookie
  behavior.
- [ ] Targeted plugin tests, full core tests, and StandardRB all exit 0.

## STOP conditions

Stop and report back if:

- A plugin suite depends on an external package or client runtime outside core.
- A missing behavior would require new feature design rather than tests.
- A source fix touches core route/session code outside this plan's scope.
- A verification command fails twice after a reasonable fix attempt.

## Maintenance notes

These plugins are easier to regress because many act through hooks. Reviewers
should prefer tests that assert final cookies, headers, stored rows, and user
fields over tests that only inspect plugin hash structure.
