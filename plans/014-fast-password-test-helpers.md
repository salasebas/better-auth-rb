# Plan 014: Use explicit fast password callbacks in high-volume tests

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report; do not improvise. When done, update the status row for this plan in
> `plans/README.md` unless a reviewer told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 7920aee..HEAD -- packages/better_auth/lib/better_auth/password.rb packages/better_auth/test/test_helper.rb packages/better_auth/test/better_auth/routes/sign_up_test.rb packages/better_auth-api-key/test/better_auth/api_key/test_support.rb packages/better_auth-api-key/test/better_auth/api_key_test.rb packages/better_auth-stripe/test/support/stripe_helpers.rb packages/better_auth-sso/test/support/sso_test_helpers.rb packages/better_auth/test/better_auth/plugins/mcp/test_helper.rb`
>
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plan 013 preferred, but not strictly required for targeted files
- **Category**: perf
- **Planned at**: commit `7920aee`, 2026-06-15

## Why this matters

Many tests create users through the real sign-up and sign-in routes even when
the behavior under test is unrelated to password hashing. The default password
hasher is scrypt, and one measured hash costs roughly 65 ms on the audit
machine. A targeted experiment on `packages/better_auth-api-key/test/better_auth/api_key_test.rb`
kept the same 101 runs and 541 assertions while reducing wall time from about
9.97 seconds to about 4.47 seconds by replacing only password hash/verify with
deterministic test callbacks.

## Current state

- Default password hashing is intentionally expensive:

```ruby
# packages/better_auth/lib/better_auth/password.rb:12-17
SCRYPT = {
  N: 16_384,
  r: 16,
  p: 1,
  length: 64
}.freeze

# packages/better_auth/lib/better_auth/password.rb:21-28
def hash(password, hasher: nil, algorithm: :scrypt)
  return hasher.call(password) if hasher.respond_to?(:call)

  case (hasher || algorithm || :scrypt).to_sym
  when :scrypt
    hash_scrypt(password)
  when :bcrypt
    hash_bcrypt(password)
```

- High-volume package helpers enable email/password with the default hasher.
  Example from API key tests:

```ruby
# packages/better_auth-api-key/test/better_auth/api_key/test_support.rb:11-22
def build_api_key_auth(options = {})
  advanced = options.is_a?(Hash) ? options.delete(:advanced) : nil
  secondary_storage = options.is_a?(Hash) ? options.delete(:secondary_storage) : nil
  session = options.is_a?(Hash) ? options.delete(:session) : nil
  BetterAuth.auth({
    secret: SECRET,
    email_and_password: {enabled: true},
    advanced: advanced,
    secondary_storage: secondary_storage,
    session: session,
    plugins: [BetterAuth::Plugins.api_key(options)]
  }.compact)
end
```

- The same helper signs up users through the public route, so every call hashes
  a password unless the auth config supplies callbacks:

```ruby
# packages/better_auth-api-key/test/better_auth/api_key/test_support.rb:25-30
def sign_up_cookie(auth, email:)
  _status, headers, _body = auth.api.sign_up_email(
    body: {email: email, password: "password123", name: "API Key"},
    as_response: true
  )
  headers.fetch("set-cookie").to_s.lines.map { |line| line.split(";").first }.join("; ")
end
```

- Some tests explicitly validate real hashing and must keep using real
  scrypt/bcrypt behavior:

```ruby
# packages/better_auth/test/better_auth/routes/sign_up_test.rb:44-55
def test_sign_up_email_uses_configured_bcrypt_hasher
  auth = build_auth(password_hasher: :bcrypt)
  # ...
  assert_match(/\Abcrypt_sha256\$/, account["password"])
  assert BetterAuth::Password.verify(password: "password123", hash: account["password"])
end
```

- Audit inventory found many sign-up/sign-in helpers:
  `rg "sign_up_cookie|sign_up_email|sign_in_email" packages test` reported
  1419 matches across 99 files. Do not migrate every call blindly; start with
  shared builders that create many users and do not assert password hashing.

## Commands you will need

If your shell resolves to macOS system Ruby 2.6, prefix commands with
`PATH="$HOME/.rbenv/shims:$HOME/.rbenv/bin:$PATH"`.

| Purpose | Command | Expected on success |
| --- | --- | --- |
| API key target | `cd packages/better_auth-api-key && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest test/better_auth/api_key_test.rb` | exit 0, 101 runs, 541 assertions |
| API key package | `cd packages/better_auth-api-key && BUNDLE_GEMFILE=Gemfile bundle exec rake test` | exit 0, ignoring unrelated plan-013 MSSQL failure if plan 013 has not landed and MSSQL is reachable |
| Core password coverage | `cd packages/better_auth && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest test/better_auth/routes/sign_up_test.rb` | exit 0; bcrypt/custom password assertions still use real behavior where intended |
| Core suite | `cd packages/better_auth && BUNDLE_GEMFILE=Gemfile bundle exec rake test` | exit 0 after plan 013; if plan 013 has not landed, only the known access-control errors may remain |

## Scope

**In scope**:

- `packages/better_auth/test/test_helper.rb`
- `packages/better_auth-api-key/test/better_auth/api_key/test_support.rb`
- `packages/better_auth-api-key/test/better_auth/api_key_test.rb`
- `packages/better_auth-stripe/test/support/stripe_helpers.rb`
- `packages/better_auth-sso/test/support/sso_test_helpers.rb`
- `packages/better_auth/test/better_auth/plugins/mcp/test_helper.rb`
- Other package-level test helper files with the same pattern, but only when a
  local targeted run shows the helper creates many users and does not assert
  password hashing.

**Out of scope**:

- Production code under `packages/**/lib`.
- Global monkeypatching of `BetterAuth::Password`.
- Tests that assert scrypt, bcrypt, password normalization, verifier arity, or
  custom password callbacks.
- New dependencies.
- CI workflow changes.

## Git workflow

- Do not commit, push, or open a PR unless the operator explicitly asks.
- Keep changes in test helper files only.

## Steps

### Step 1: Add a shared explicit fast password config for tests

In `packages/better_auth/test/test_helper.rb`, add a small helper module that
returns an `email_and_password` config using deterministic callbacks. The shape
must match the existing production callback API rather than monkeypatching
`BetterAuth::Password`.

Target behavior:

- `hash.call("password123")` returns a deterministic string, for example
  `"test-password:password123"`.
- `verify.call(password: "password123", hash: "test-password:password123")`
  returns true.
- The verifier should also tolerate the single-hash-argument style used by
  existing tests if that is how `Password.call_verifier` passes keywords in the
  current Ruby version.
- The helper should make it easy to merge local overrides without overwriting
  test-specific `email_and_password` options.

Name suggestion:

```ruby
module BetterAuthTestPasswordHelpers
  def fast_email_and_password_config(overrides = {})
    # returns {enabled: true, password: {hash: ..., verify: ...}} merged with overrides
  end
end
```

Include the helper into the base Minitest test class or expose it from
`test_helper.rb` in the same style as existing shared test helpers.

**Verify**:
`cd packages/better_auth && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest test/better_auth/routes/sign_up_test.rb`
-> exit 0.

### Step 2: Use the helper in high-volume package auth builders

Update package test builders that currently hard-code
`email_and_password: {enabled: true}` and are not testing password hashing.
Start with these known high-impact files:

- `packages/better_auth-api-key/test/better_auth/api_key/test_support.rb`
- the duplicate builder near the bottom of
  `packages/better_auth-api-key/test/better_auth/api_key_test.rb`
- `packages/better_auth-stripe/test/support/stripe_helpers.rb`
- `packages/better_auth-sso/test/support/sso_test_helpers.rb`
- `packages/better_auth/test/better_auth/plugins/mcp/test_helper.rb`

When changing a builder, preserve caller overrides. If a caller passes its own
`email_and_password`, do not replace it with the fast config. If a caller passes
only unrelated plugin options, use the fast config by default.

**Verify**:
`cd packages/better_auth-api-key && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest test/better_auth/api_key_test.rb`
-> exit 0, 101 runs, 541 assertions.

### Step 3: Expand only where timing proves value

Run package-level targets for migrated helpers and record before/after wall
times in the PR notes. Use `time` locally, but do not add brittle timing
assertions to tests.

Candidate commands:

```bash
cd packages/better_auth-api-key && time BUNDLE_GEMFILE=Gemfile bundle exec rake test
cd packages/better_auth-stripe && time BUNDLE_GEMFILE=Gemfile bundle exec rake test
cd packages/better_auth-sso && time BUNDLE_GEMFILE=Gemfile bundle exec rake test
```

Migrate additional helper files only when they meet both conditions:

- They create users through `sign_up_email`/`sign_in_email` many times.
- They do not assert stored password format, scrypt/bcrypt behavior, verifier
  behavior, password normalization, or invalid-password security behavior.

**Verify**:
Every package target touched in this step exits 0.

## Test plan

- Existing route tests continue to validate real bcrypt and configured password
  callbacks.
- Existing package tests should keep the same run/assertion counts after the
  helper migration.
- No new production tests are needed unless the helper has behavior complex
  enough to warrant a small test in an existing test-helper-focused file.

## Done criteria

- [ ] `packages/better_auth/test/test_helper.rb` exposes an explicit fast
      password config helper.
- [ ] At least the API key high-volume helper uses the fast config by default
      while preserving caller overrides.
- [ ] `cd packages/better_auth-api-key && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest test/better_auth/api_key_test.rb`
      exits 0 with the same run/assertion count.
- [ ] `cd packages/better_auth && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest test/better_auth/routes/sign_up_test.rb`
      exits 0.
- [ ] No production files under `packages/**/lib` are modified.
- [ ] `plans/README.md` status row for plan 014 is updated.

## STOP conditions

Stop and report if:

- The live code no longer matches the excerpts above.
- A migrated test asserts on password hash format or real verifier behavior.
- The fast helper requires changing production password APIs.
- A package-level test changes run/assertion count unexpectedly.
- A verification command fails twice after a reasonable fix attempt.

## Maintenance notes

- This plan intentionally avoids global monkeypatching. Future tests that need
  speed should opt into the helper through their local auth builder.
- Keep at least one real route-level password-hashing path in core tests so
  scrypt/bcrypt regressions remain observable.
