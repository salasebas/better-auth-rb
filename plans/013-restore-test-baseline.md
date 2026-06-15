# Plan 013: Restore the full test baseline before optimizing suites

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report; do not improvise. When done, update the status row for this plan in
> `plans/README.md` unless a reviewer told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 7920aee..HEAD -- packages/better_auth/lib/better_auth/plugins.rb packages/better_auth/test/better_auth/plugins/access_test.rb packages/better_auth/lib/better_auth/adapters/mssql.rb packages/better_auth/lib/better_auth/adapters/sql.rb packages/better_auth-api-key/test/better_auth/api_key/adapter_matrix_test.rb packages/better_auth-passkey/test/better_auth/passkey/adapter_matrix_test.rb`
>
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `7920aee`, 2026-06-15

## Why this matters

The current full test audit does not have a green baseline. Core tests fail
because `BetterAuth::Plugins.create_access_control` is missing, and adapter
matrix tests fail against a real MSSQL service because the MSSQL adapter method
signature no longer matches the shared SQL adapter call shape. Test speed work
and a new integration workflow should not land on top of a known-red baseline
because that would make future regressions indistinguishable from existing
failures.

## Current state

- `packages/better_auth/test/better_auth/plugins/access_test.rb` is a core
  Minitest file for access-control plugin behavior. It expects both snake_case
  and camelCase access-control factories:

```ruby
# packages/better_auth/test/better_auth/plugins/access_test.rb:11
@ac = BetterAuth::Plugins.create_access_control(statements)

# packages/better_auth/test/better_auth/plugins/access_test.rb:103-106
def test_create_access_control_has_camel_case_alias
  ac = BetterAuth::Plugins.createAccessControl(project: ["read"])
  assert_equal true, ac.newRole(project: ["read"]).authorize(project: ["read"]).fetch(:success)
end
```

- `packages/better_auth/lib/better_auth/plugins.rb` currently lazy-loads plugin
  methods and raises through `method_missing` when the plugin file does not
  define the expected method:

```ruby
# packages/better_auth/lib/better_auth/plugins.rb:58-66
def method_missing(name, ...)
  if lazy_plugin_method?(name)
    load_plugin!(name)
    return public_send(name, ...) if respond_to?(name, true)

    raise NoMethodError, "plugin file for #{name} did not define BetterAuth::Plugins.#{name}"
  end

  super
end
```

- A targeted run of
  `cd packages/better_auth && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest test/better_auth/plugins/access_test.rb`
  currently errors 10 times with:
  `NoMethodError: undefined method 'create_access_control' for module BetterAuth::Plugins`.

- `packages/better_auth/lib/better_auth/adapters/sql.rb` now passes keyword
  options to `execute` for non-returning update/delete operations:

```ruby
# packages/better_auth/lib/better_auth/adapters/sql.rb:81-99
def update_many(model:, where:, update:, returning: false)
  # ...
  result = execute(sql, params, affected_rows_result: !returning)
  return result.map { |row| normalize_record(model, row) } if returning

  affected_rows(result)
end

# packages/better_auth/lib/better_auth/adapters/sql.rb:109-117
def delete_many(model:, where:)
  # ...
  result = execute(sql, params, affected_rows_result: true)
  affected_rows(result)
end
```

- `packages/better_auth/lib/better_auth/adapters/mssql.rb` overrides
  `execute` with only two positional parameters:

```ruby
# packages/better_auth/lib/better_auth/adapters/mssql.rb:27-33
def execute(sql, params)
  if connection.respond_to?(:fetch)
    connection.fetch(sql, *params).all.map { |row| stringify_row(row) }
  else
    super
  end
end
```

- With MSSQL reachable locally, these tests fail:
  - `packages/better_auth-api-key/test/better_auth/api_key/adapter_matrix_test.rb:87-105`
    with `ArgumentError: wrong number of arguments (given 3, expected 2)` from
    `packages/better_auth/lib/better_auth/adapters/mssql.rb:27`.
  - `packages/better_auth-passkey/test/better_auth/passkey/adapter_matrix_test.rb:70-90`
    with the same error from the same MSSQL adapter method.

## Commands you will need

If your shell resolves to macOS system Ruby 2.6, prefix commands with
`PATH="$HOME/.rbenv/shims:$HOME/.rbenv/bin:$PATH"`.

| Purpose | Command | Expected on success |
| --- | --- | --- |
| Access-control target | `cd packages/better_auth && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest test/better_auth/plugins/access_test.rb` | exit 0 |
| API key MSSQL target | `cd packages/better_auth-api-key && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest test/better_auth/api_key/adapter_matrix_test.rb` | exit 0; MSSQL case passes when service is reachable, skips only when service is absent |
| Passkey MSSQL target | `cd packages/better_auth-passkey && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest test/better_auth/passkey/adapter_matrix_test.rb` | exit 0; MSSQL case passes when service is reachable, skips only when service is absent |
| Core suite | `cd packages/better_auth && BUNDLE_GEMFILE=Gemfile bundle exec rake test` | exit 0 |

## Scope

**In scope**:

- `packages/better_auth/lib/better_auth/plugins.rb`
- `packages/better_auth/lib/better_auth/plugins/access.rb` or the existing
  access-control implementation file if it already exists under
  `packages/better_auth/lib/better_auth/plugins/`
- `packages/better_auth/test/better_auth/plugins/access_test.rb`
- `packages/better_auth/lib/better_auth/adapters/mssql.rb`
- Narrow regression tests in the existing adapter matrix test files if needed:
  - `packages/better_auth-api-key/test/better_auth/api_key/adapter_matrix_test.rb`
  - `packages/better_auth-passkey/test/better_auth/passkey/adapter_matrix_test.rb`

**Out of scope**:

- Any CI workflow reshaping. That belongs to plan 015.
- Any password hashing test speed work. That belongs to plan 014.
- New dependencies.
- Rewriting adapter matrix coverage or changing which services are considered
  integration tests.

## Git workflow

- Do not commit, push, or open a PR unless the operator explicitly asks.
- Keep the fix in the smallest set of files listed in Scope.

## Steps

### Step 1: Restore the access-control plugin factory API

Inspect `packages/better_auth/lib/better_auth/plugin_loader.rb` and the
existing plugin files under `packages/better_auth/lib/better_auth/plugins/`.
Find whether an access-control implementation already exists but is not
registered, or whether it was removed.

If upstream behavior is needed, fetch/read the Better Auth v1.6.9 source and
tests using the repository script:

```bash
./scripts/fetch-upstream-better-auth.sh
```

Then read the upstream access-control source and tests under
`reference/upstream-src/1.6.9/repository/`. Do not commit anything under
`reference/upstream-src/`.

Implement the missing Ruby API so these entry points exist and behave as the
current test expects:

- `BetterAuth::Plugins.create_access_control`
- `BetterAuth::Plugins.createAccessControl`
- role methods used by the test, including snake_case and camelCase aliases
  such as `new_role` and `newRole`.

Preserve the Ruby adaptation already asserted by
`test_accepts_lowercase_connectors_as_ruby_adaptation`.

**Verify**:
`cd packages/better_auth && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest test/better_auth/plugins/access_test.rb`
-> exit 0.

### Step 2: Fix the MSSQL adapter execute signature

Update `packages/better_auth/lib/better_auth/adapters/mssql.rb` so its private
`execute` override accepts the same call shape as the shared SQL adapter. The
minimum required compatibility is:

- It must accept `execute(sql, params, affected_rows_result: true)` from
  `SQL#update_many` and `SQL#delete_many`.
- It must preserve existing select behavior using `connection.fetch(sql, *params)`.
- It must return a value that `SQL#affected_rows(result)` can interpret for
  update/delete statements.

Before changing return behavior, inspect `SQL#execute`, `SQL#affected_rows`, and
any MSSQL-specific tests so the MSSQL override matches the shared adapter
contract rather than special-casing only the two failing tests.

**Verify**:
`cd packages/better_auth-api-key && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest test/better_auth/api_key/adapter_matrix_test.rb`
-> exit 0 when services are available; otherwise only service-unavailable skips.

**Verify**:
`cd packages/better_auth-passkey && BUNDLE_GEMFILE=Gemfile bundle exec ruby -Itest test/better_auth/passkey/adapter_matrix_test.rb`
-> exit 0 when services are available; otherwise only service-unavailable skips.

### Step 3: Re-run the core baseline

Run the core suite after both fixes so the known access-control errors are gone
and no shared adapter changes broke core behavior.

**Verify**:
`cd packages/better_auth && BUNDLE_GEMFILE=Gemfile bundle exec rake test`
-> exit 0.

## Test plan

- Existing `packages/better_auth/test/better_auth/plugins/access_test.rb`
  already covers:
  - direct statements passed into `new_role`
  - denied unknown actions and unknown resources
  - AND/OR connector behavior
  - malformed resource requests
  - snake_case and camelCase public API names
- Existing adapter matrix tests already cover the MSSQL regression path through
  real create/update/delete calls:
  - `packages/better_auth-api-key/test/better_auth/api_key/adapter_matrix_test.rb`
  - `packages/better_auth-passkey/test/better_auth/passkey/adapter_matrix_test.rb`
- Add new tests only if the implementation needs a narrower assertion to
  protect an edge case not covered by those files.

## Done criteria

- [ ] Access-control target command exits 0.
- [ ] API key adapter matrix exits 0, with MSSQL passing when MSSQL is reachable.
- [ ] Passkey adapter matrix exits 0, with MSSQL passing when MSSQL is reachable.
- [ ] `cd packages/better_auth && BUNDLE_GEMFILE=Gemfile bundle exec rake test`
      exits 0.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row for plan 013 is updated.

## STOP conditions

Stop and report if:

- The live code no longer matches the excerpts above.
- Upstream Better Auth v1.6.9 access-control behavior conflicts with the
  existing Ruby tests in a way that requires changing public behavior.
- Fixing MSSQL requires changing the shared SQL adapter contract for every SQL
  adapter.
- A verification command fails twice after a reasonable fix attempt.
- The fix appears to require a new gem.

## Maintenance notes

- Plan 015 should not be executed until this plan is done or explicitly
  rejected, because integration workflows should not encode currently failing
  MSSQL behavior as expected.
- Reviewers should pay close attention to whether the MSSQL change preserves
  affected-row semantics for update/delete without breaking select queries.
