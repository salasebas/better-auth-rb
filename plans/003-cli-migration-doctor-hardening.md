# Plan 003: Harden Migration, Status, And Doctor Tests

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 7920aee..HEAD -- packages/better_auth-cli packages/better_auth/lib/better_auth/doctor.rb packages/better_auth/lib/better_auth/sql_migration.rb packages/better_auth/test/better_auth/doctor_test.rb packages/better_auth/test/better_auth/migration/sql_test.rb .github/workflows/ci.yml`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/001-cli-command-contract-characterization.md`,
  `plans/002-cli-schema-upstream-parity-matrix.md`
- **Category**: tests
- **Planned at**: commit `7920aee`, 2026-06-14

## Why This Matters

`migrate`, `migrate status`, and `doctor` are Ruby-specific operational
commands. They decide whether a production app can safely apply auth schema and
whether a config is safe enough to run. The current suite checks basic success
and warnings, but not whether migrated schema supports actual auth writes,
whether plugin tables are usable, whether status reports additions/indexes/type
warnings, or whether failures leave a clear operator signal.

## Current State

Current CLI migration tests:

```ruby
# packages/better_auth-cli/test/better_auth/cli_test.rb:243
def test_migrate_applies_pending_schema_and_repeated_migrate_reports_no_changes
  ...
  assert_includes stdout, "migration completed successfully."
  assert_includes sqlite_tables(dir), "users"
```

Current status output:

```ruby
# packages/better_auth-cli/lib/better_auth/cli.rb:103
if plan.empty?
  stdout.puts "No migrations needed."
else
  plan.to_create.each { |change| stdout.puts "create table #{change.table_name}" }
  plan.to_add.each { |change| stdout.puts "add #{change.fields.keys.join(", ")} to #{change.table_name}" }
  plan.to_index.each { |change| stdout.puts "create index #{change.name}" }
  plan.warnings.each { |warning| stdout.puts "warning: #{warning}" }
end
```

Current doctor behavior:

```ruby
# packages/better_auth/lib/better_auth/doctor.rb:27
def print(result, stdout:, stderr:)
  result.ok.each { |message| stdout.puts "OK #{message}" }
  result.warnings.each { |message| stdout.puts "WARN #{message}" }
  result.errors.each { |message| stderr.puts "ERROR #{message}" }
  result.success? ? 0 : 1
end
```

Upstream migrate tests verify that migrated schema supports auth writes and
plugin table writes:

```ts
// reference/upstream-src/1.6.9/repository/packages/cli/test/migrate.test.ts:26
it("should migrate the database and sign-up a user", async () => {

// reference/upstream-src/1.6.9/repository/packages/cli/test/migrate.test.ts:75
it("should migrate the database and sign-up a user", async () => {
```

CI currently runs CLI tests without database services:

```yaml
# .github/workflows/ci.yml:221
test-cli:
  name: Test better_auth-cli
  ...
  run: timeout 180s bundle exec rake test
```

## Ruby Migration & Plugin Model

This plan hardens **SQL migration commands only**. Keep these rules in mind when
writing tests and fixtures.

**Desired vs actual schema**

1. Load/eval config → `BetterAuth::Schema.auth_tables(config)` builds desired
   tables from core options + every `plugin.schema` + `additional_fields`.
2. `BetterAuth::SQLMigration.plan` introspects the live DB via
   `current_schema(connection, dialect)` (sqlite pragma / information_schema).
3. Diff produces `to_create` (missing tables), `to_add` (missing columns on
   existing tables), `to_index` (missing indexes), and `warnings` (type
   mismatches).

**Plugin registration**

- Only plugins listed in `plugins:` inside the config file affect the plan.
- Adding a plugin later without re-running `migrate` / `generate` leaves schema
  drift; `doctor` should warn via `check_database`.
- `additional_fields` on `user`/`session` or the `additional-fields` plugin
  produce `to_add` / `to_index` on existing core tables, not new tables.

**Command surfaces**

| Command | Behavior |
| --- | --- |
| `migrate --yes` | Applies pending SQL inline via `migrate_pending` |
| `migrate status` | Prints human plan from `SQLMigration.plan` |
| `doctor` | Includes schema drift warning when adapter supports introspection |
| `mongo indexes` | **Not SQL** — separate Mongo index setup; out of scope here |

**Not covered by CLI migrate**

- Rails/Hanami/Sinatra/Roda/Grape framework generators write AR migrations or
  `.sql` files; they reuse the same `SQLMigration.plan` logic but are not
  exercised in this plan unless a test explicitly needs them.

Upstream analogue: `getMigrations` in
`reference/upstream-src/1.6.9/repository/packages/better-auth/src/db/get-migration.ts`
(Kysely-only). Ruby uses core SQL adapters with `connection` + `dialect`.

## Commands You Will Need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| CLI tests | `cd packages/better_auth-cli && bundle exec rake test` | exit 0 |
| Core doctor tests | `cd packages/better_auth && bundle exec ruby -Itest -Ilib test/better_auth/doctor_test.rb` | exit 0 |
| Core migration tests | `cd packages/better_auth && bundle exec ruby -Itest -Ilib test/better_auth/migration/sql_test.rb` | exit 0 |
| Lint touched files | `bundle exec standardrb packages/better_auth-cli/lib packages/better_auth-cli/test packages/better_auth/lib/better_auth/doctor.rb packages/better_auth/lib/better_auth/sql_migration.rb packages/better_auth/test/better_auth/doctor_test.rb packages/better_auth/test/better_auth/migration/sql_test.rb` | exit 0 |

## Scope

**In scope**:

- `packages/better_auth-cli/test/better_auth/cli_test.rb`
- `packages/better_auth-cli/test/support/cli_helpers.rb`
- `packages/better_auth/lib/better_auth/doctor.rb`
- `packages/better_auth/test/better_auth/doctor_test.rb`
- `packages/better_auth/lib/better_auth/sql_migration.rb` only if tests expose
  confirmed migration/status bugs.
- `packages/better_auth/test/better_auth/migration/sql_test.rb`

**Out of scope**:

- JSON output for doctor/info. That belongs to plan 005.
- Config discovery. That belongs to plan 004.
- New database services in CI unless optional env-gated tests already fit the
  existing workflow.

## Git Workflow

- Branch: `test/cli-migration-doctor-hardening`
- Commit message style: `test(cli): harden migration and doctor coverage`
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Verify migrated SQLite schema supports auth writes

Add a CLI test that:

- Creates a temp sqlite config with `email_and_password: {enabled: true}`.
- Runs `better-auth migrate --config <path> --yes`.
- Loads the same config through `BetterAuth.auth` or the CLI config helper.
- Calls the Ruby API equivalent of email sign-up against the migrated database.
- Asserts the result contains a token or that the user/account/session rows
  required by the API exist.

This ports the upstream migrate intent while staying Ruby-native.

**Verify**: `cd packages/better_auth-cli && bundle exec rake test` -> exit 0.

### Step 2: Verify migrated plugin schema is writable

Add a CLI test that:

- Configures a simple custom plugin with a table **in the `plugins:` array**, or
  a built-in plugin that is available without cross-package dependencies.
- Runs `migrate --yes`.
- Inserts a row into the plugin table through the sqlite connection or through
  the public adapter if available.
- Asserts the insert succeeds.

Prefer a custom plugin fixture to avoid coupling `better_auth-cli` to optional
plugin package load paths. The fixture should mirror how real apps register
plugins:

```ruby
plugins: [
  BetterAuth::Plugin.new(
    id: "audit-test",
    schema: { auditLog: { model_name: "audit_logs", fields: { ... } } }
  )
]
```

**Verify**: `cd packages/better_auth-cli && bundle exec rake test` -> exit 0.

### Step 3: Expand `migrate status` coverage

Add tests for status output that cover:

- Pending `add <fields> to <table>` when a table exists but additional fields
  are missing (e.g. add `role` to `users` after core migration, then extend
  config with `user: {additional_fields: {role: ...}}`).
- Pending `create index <name>` when an indexed additional field is missing its
  index.
- Pending `create table` when a new plugin is added to `plugins:` after core
  tables already exist.
- Type mismatch warnings from `SQLMigration.plan`.
- No duplicate entries after applying migration.

Use real sqlite where possible. For non-sqlite dialect formatting, reuse fake
SQL adapters only for output shape; do not pretend they verify real database
introspection.

**Verify**: `cd packages/better_auth-cli && bundle exec rake test` -> exit 0.

### Step 4: Harden doctor tests around all check branches

Add core tests in `packages/better_auth/test/better_auth/doctor_test.rb` and
CLI tests in `cli_test.rb` for:

- Missing secret returns an error.
- Short secret returns an error.
- Low entropy long secret returns an error.
- Missing `base_url` returns a warning.
- HTTP `base_url` returns a warning.
- HTTPS `base_url` returns OK.
- Memory rate-limit storage warns.
- Database and secondary-storage rate-limit storage are OK.
- Unsupported/non-introspectable adapter emits the schema drift skipped warning.
- Type mismatch warnings from the migration planner surface through doctor.

Do not change warning/error text unless required for clarity; tests may assert
substrings.

**Verify**:
`cd packages/better_auth && bundle exec ruby -Itest -Ilib test/better_auth/doctor_test.rb`
and `cd packages/better_auth-cli && bundle exec rake test` -> both exit 0.

### Step 5: Add failure behavior tests for migration execution

Add or extend core migration tests so failures are observable:

- If a pending migration statement fails inside `migrate_pending`, the method
  raises and does not return true.
- If the adapter exposes `transaction`, `migrate_pending` uses it.
- If the SQL connection supports only `execute`, it still works.
- If the SQL connection supports neither `exec`, `execute`, nor `query`, the
  error is concise and mentions supported methods.

Only change `SQLMigration` if a new test proves current behavior is wrong.

**Verify**:
`cd packages/better_auth && bundle exec ruby -Itest -Ilib test/better_auth/migration/sql_test.rb`
-> exit 0.

### Step 6: Decide on optional real database CLI integration

The helper already contains:

```ruby
# packages/better_auth-cli/test/support/cli_helpers.rb:110
def db_integration_enabled?
  ENV["BETTER_AUTH_CLI_RUN_DB_INTEGRATION"] == "1"
end
```

Either:

- Add env-gated CLI tests for postgres/mysql if the existing package Gemfile
  already has the needed adapter gems available transitively, or
- Leave a short comment explaining why the package-level CLI suite remains
  sqlite-only and core owns real postgres/mysql/mssql integration.

Do not add dependencies without asking.

**Verify**: `cd packages/better_auth-cli && bundle exec rake test` -> exit 0.

### Step 7: Run lint

**Verify**:
`bundle exec standardrb packages/better_auth-cli/lib packages/better_auth-cli/test packages/better_auth/lib/better_auth/doctor.rb packages/better_auth/lib/better_auth/sql_migration.rb packages/better_auth/test/better_auth/doctor_test.rb packages/better_auth/test/better_auth/migration/sql_test.rb`
-> exit 0.

## Test Plan

- CLI tests should prove command-level behavior with real sqlite temp files.
- Core tests should prove lower-level migration and doctor branch behavior.
- Optional database integration tests must be skipped by default and enabled
  only with `BETTER_AUTH_CLI_RUN_DB_INTEGRATION=1`.

## Done Criteria

- [ ] CLI migration tests prove migrated schema can sign up a user or persist
  the required auth records.
- [ ] CLI migration tests prove a plugin table created by migration is writable.
- [ ] `migrate status` tests cover create, add, index, warning, and no-change
  output.
- [ ] Doctor tests cover every branch in `check_secret`, `check_base_url`,
  `check_rate_limit`, and `check_database`.
- [ ] All commands in "Commands You Will Need" exit 0.
- [ ] `plans/README.md` status row for plan 003 is updated.

## STOP Conditions

Stop and report if:

- The public Ruby API cannot sign up a user from CLI tests without adding
  brittle test-only access.
- Plugin writable tests require loading optional plugin packages not available
  to `better_auth-cli`.
- Real database CLI integration needs new dependencies.
- Fixing doctor output would require breaking documented message text.

## Maintenance Notes

Keep operational command tests focused on what an operator sees: exit status,
stdout/stderr, database side effects, and idempotency. Core tests should keep
owning SQL planner details so CLI tests do not become snapshots of the entire
schema.
