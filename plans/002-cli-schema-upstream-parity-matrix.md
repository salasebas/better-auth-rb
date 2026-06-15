# Plan 002: Add Upstream-Backed Schema Generation Parity Matrix

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 7920aee..HEAD -- packages/better_auth-cli packages/better_auth/lib/better_auth/schema.rb packages/better_auth/lib/better_auth/schema/sql.rb packages/better_auth/lib/better_auth/sql_migration.rb packages/better_auth/test/better_auth/migration packages/better_auth/test/better_auth/schema reference/upstream-src/1.6.9/repository/packages/cli/test`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: `plans/001-cli-command-contract-characterization.md`
- **Category**: tests
- **Planned at**: commit `7920aee`, 2026-06-14

## Why This Matters

Upstream Better Auth treats schema generation as a high-risk CLI surface and
tests many dialect, plugin, custom naming, JSON, enum, and adapter combinations.
The Ruby CLI currently tests only coarse SQL snippets. A Ruby-specific parity
matrix should not copy Prisma/Drizzle behavior, but it should port the same
schema risks into SQL migration and CLI integration tests.

## Current State

Relevant files:

- `packages/better_auth-cli/test/better_auth/cli_test.rb` - CLI integration
  tests currently assert only a few SQL fragments.
- `packages/better_auth/test/better_auth/migration/sql_test.rb` - core SQL
  migration tests.
- `packages/better_auth/test/better_auth/schema_test.rb` and
  `packages/better_auth/test/better_auth/schema/sql_test.rb` - schema behavior
  tests.
- `packages/better_auth/lib/better_auth/schema.rb` and
  `packages/better_auth/lib/better_auth/schema/sql.rb` - schema source of
  truth.

Current CLI schema assertions are shallow:

```ruby
# packages/better_auth-cli/test/better_auth/cli_test.rb:172
def test_generate_writes_incremental_sql
  ...
  assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "users"'
end

# packages/better_auth-cli/test/better_auth/cli_test.rb:201
def test_generate_includes_plugin_schema
  ...
  assert_includes File.read(output), 'CREATE TABLE IF NOT EXISTS "audit_logs"'
end
```

Core SQL type mapping exists but needs a matrix around it:

```ruby
# packages/better_auth/lib/better_auth/schema/sql.rb:151
def sql_type(logical_field, attributes, dialect)
  case attributes[:type]
  when "boolean"
  ...
  when "json", "string[]", "number[]"
```

Upstream generator coverage includes omitted `required`, JSON fields, enum
fields, unsupported field types, custom model names, usePlural, dialect matrix,
and passkey plugin combinations:

```ts
// reference/upstream-src/1.6.9/repository/packages/cli/test/generate.test.ts:266
it("should treat fields with omitted required as notNull (default true)", async () => {

// reference/upstream-src/1.6.9/repository/packages/cli/test/generate.test.ts:522
describe("JSON field support in CLI generators", () => {

// reference/upstream-src/1.6.9/repository/packages/cli/test/generate-all-db.test.ts:299
describe("generate drizzle schema for all databases with passkey plugin", async () => {
```

Important Ruby adaptation:

- Ruby does not generate Prisma or Drizzle schemas in `better_auth-cli`.
- Ruby uses snake_case physical column names by convention.
- Upstream `generateId: "serial"` maps to Ruby `advanced: {database:
  {generate_id: "serial"}}`.
- Upstream enum array types may not currently be a Ruby SQL field type. If the
  schema layer does not support enum fields, this plan should add an
  explicit unsupported-type test or a Ruby adaptation note instead of quietly
  inventing enum SQL semantics.

## Ruby Schema & Migration Model

Executors working on schema or migration tests must understand this contract.
It is the Ruby equivalent of upstream `getAuthTables` + `getSchema` +
`getMigrations`, but applied through SQL adapters instead of Kysely.

**How the desired schema is built**

- `BetterAuth::Schema.auth_tables(config)` is the source of truth.
- Core tables: `user`, `session`, `account`, `verification`, optional
  `rateLimit`.
- Each entry in `config.plugins` may contribute `plugin.schema` tables/fields.
  Plugins are **not** discovered at runtime; only what is in the eval'd config
  file counts.
- `user.additional_fields`, `session.additional_fields`, etc. merge into core
  tables the same way as upstream `options.user.additionalFields`.
- `BetterAuth::Plugins.additional_fields(...)` is equivalent: it sets plugin
  schema **and** copies fields into options via `init`.
- External gems (`BetterAuth::Plugins.api_key`, `passkey`, `stripe`, etc.) must
  still appear in `plugins:`; the shim loads the gem, but migration only sees
  the returned `Plugin` object's `schema`.

**What Ruby does not generate**

- No Prisma, Drizzle, or Kysely schema output. CLI `generate` writes SQL only.
- MongoDB uses `better-auth mongo indexes`, not SQL migration.

**Physical naming**

- Logical keys (`apiKey`, `userId`) map to snake_case columns/tables in SQL
  (`api_keys`, `user_id`). Tests should assert physical names in SQL output.

**Incremental vs full generate**

- With a SQL connection, CLI/core use `SQLMigration.render_pending`, which
  introspects the live DB (`current_schema`) and emits only missing tables,
  columns, and indexes.
- Without a connection, `render` emits the full schema.

Upstream reference for risk cases (not line-by-line port):
`reference/upstream-src/1.6.9/repository/packages/better-auth/src/db/get-migration.ts`
and `packages/core/src/db/get-tables.ts`.

## Commands You Will Need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Core focused tests | `cd packages/better_auth && bundle exec ruby -Itest -Ilib test/better_auth/migration/sql_test.rb` | exit 0 |
| Core schema tests | `cd packages/better_auth && bundle exec ruby -Itest -Ilib test/better_auth/schema_test.rb test/better_auth/schema/sql_test.rb` | exit 0 |
| CLI tests | `cd packages/better_auth-cli && bundle exec rake test` | exit 0 |
| Lint touched files | `bundle exec standardrb packages/better_auth/lib packages/better_auth/test packages/better_auth-cli/lib packages/better_auth-cli/test` | exit 0 |

## Scope

**In scope**:

- `packages/better_auth-cli/test/better_auth/cli_test.rb`
- `packages/better_auth-cli/test/support/cli_helpers.rb`
- `packages/better_auth/test/better_auth/migration/sql_test.rb`
- `packages/better_auth/test/better_auth/schema_test.rb`
- `packages/better_auth/test/better_auth/schema/sql_test.rb`
- `packages/better_auth/lib/better_auth/schema.rb`,
  `packages/better_auth/lib/better_auth/schema/sql.rb`, and
  `packages/better_auth/lib/better_auth/sql_migration.rb` only if the new tests
  expose confirmed behavior gaps.

**Out of scope**:

- Prisma, Drizzle, and TypeScript ORM schema generators.
- Node package manager behavior.
- CLI prompts.
- New dependencies.

## Git Workflow

- Branch: `test/cli-schema-parity-matrix`
- Commit message style: `test(cli): add schema generation parity matrix`
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Add a parity matrix helper

Create helper methods in `packages/better_auth-cli/test/support/cli_helpers.rb`
or a new support file required by `cli_test.rb`:

- `write_sqlite_config` should accept `user_options_source:`,
  `session_options_source:`, `account_options_source:`,
  `verification_options_source:`, `advanced_source:`, and `plugins_source:`.
- Add `write_fake_sql_config` support for the same schema options.
- Keep helper values Ruby source strings where needed, because plugin factories
  like `BetterAuth::Plugins.two_factor` must execute inside the config file.

Do not make helpers clever enough to hide the schema being tested. The test
body should still show the important config.

**Verify**: `cd packages/better_auth-cli && bundle exec rake test` -> exit 0.

### Step 2: Port the dialect and custom naming matrix into core SQL tests

Add tests in `packages/better_auth/test/better_auth/migration/sql_test.rb` or
`packages/better_auth/test/better_auth/schema/sql_test.rb` for:

- For each dialect `:sqlite`, `:postgres`, `:mysql`, `:mssql`, render a full
  schema with custom core model names:
  `custom_users`, `custom_sessions`, `custom_accounts`, `custom_verifications`.
- Assert each dialect's quote style appears in create statements.
- Assert foreign keys target the custom table names and physical `id` field.
- Assert string index sizing for MySQL and MSSQL remains bounded for indexed
  fields.
- Assert `advanced: {database: {generate_id: "serial"}}` and
  `advanced: {database: {generate_id: "uuid"}}` produce the expected schema
  behavior already supported by Ruby. If SQL generation currently ignores this
  option, STOP and report whether this belongs in core schema before changing
  CLI tests.

Use upstream tests at
`reference/upstream-src/1.6.9/repository/packages/cli/test/generate-all-db.test.ts:8`
as the risk checklist, not as a line-by-line implementation source.

**Verify**:
`cd packages/better_auth && bundle exec ruby -Itest -Ilib test/better_auth/migration/sql_test.rb`
-> exit 0.

### Step 3: Add plugin schema cases from upstream risk areas

Add core SQL tests for plugin-heavy schema generation:

- `BetterAuth::Plugins.two_factor` plus `BetterAuth::Plugins.username`.
- `BetterAuth::Plugins.phone_number` because MSSQL nullable unique index
  behavior is already special-cased.
- `BetterAuth::Plugins.passkey` if available from core or required plugin
  package in the test environment. If passkey lives only in
  `packages/better_auth-passkey`, either add a package-local CLI/schema test
  there or STOP and report the cross-package dependency question.
- A custom plugin with two fields referencing the same model and another custom
  plugin with references to two different models. For SQL, assert foreign key
  constraints are generated once per field and target the correct tables.
- Config fixtures must put plugins in the `plugins:` array. A plugin class
  loaded but omitted from `plugins:` must **not** affect generated SQL.
- Cover both `user: {additional_fields: {...}}` and
  `BetterAuth::Plugins.additional_fields(...)` and assert the same physical
  columns appear on `users` / `sessions`.

Keep assertions semantic: table names, columns, foreign keys, indexes. Do not
use large snapshots.

**Verify**:
`cd packages/better_auth && bundle exec ruby -Itest -Ilib test/better_auth/migration/sql_test.rb`
-> exit 0.

### Step 4: Add additional field type and required/default coverage

Port upstream's field risk cases into Ruby SQL expectations:

- Omitted `required` on plugin fields: decide and test the current Ruby
  contract. Upstream treats omitted `required` as required. If Ruby currently
  treats omitted `required` as nullable, STOP and report because changing it may
  affect existing plugin schemas.
- Explicit `required: true` adds `NOT NULL`.
- Explicit `required: false` stays nullable.
- `type: "json"`, `type: "string[]"`, and `type: "number[]"` map to `jsonb`
  for postgres, `json` for mysql, `varchar(8000)` for mssql, and `text` for
  sqlite.
- Unsupported field type such as `"object"` raises or emits a clear error.
  If it currently silently maps to string/text, add a failing test first and
  then fix core SQL to reject unsupported field types.
- String default values are SQL-escaped.
- Boolean/numeric defaults render correctly per dialect.

**Verify**:
`cd packages/better_auth && bundle exec ruby -Itest -Ilib test/better_auth/schema/sql_test.rb test/better_auth/migration/sql_test.rb`
-> exit 0.

### Step 5: Add CLI integration tests over the matrix edges

In `packages/better_auth-cli/test/better_auth/cli_test.rb`, add a smaller set
of end-to-end `generate` tests that prove CLI wiring reaches the core matrix:

- Generate with custom model names and assert the output file includes the
  custom table names.
- Generate with JSON/array additional fields and assert dialect-specific types
  for sqlite and postgres using fake SQL adapters.
- Generate with a plugin table and assert indexes appear in `migrate status`
  output.
- Generate after applying core tables only, then add a plugin to config and
  assert `render_pending` / `migrate status` reports `create table` for the new
  plugin table (incremental path).
- Generate with unsupported field type and assert status 1 with a concise
  error on stderr.

Do not replicate every core matrix case in CLI tests.

**Verify**: `cd packages/better_auth-cli && bundle exec rake test` -> exit 0.

### Step 6: Document Ruby-specific adaptations in tests

Add short comments only where they prevent future upstream parity confusion:

- Ruby CLI generates SQL only, not Prisma/Drizzle schemas.
- Ruby physical names are snake_case.
- Enum array support should be explicitly unsupported or documented as a Ruby
  adaptation until implemented.

Do not add broad prose docs in this plan unless behavior changes.

**Verify**:
`bundle exec standardrb packages/better_auth/lib packages/better_auth/test packages/better_auth-cli/lib packages/better_auth-cli/test`
-> exit 0.

## Test Plan

- Core SQL tests should own the full matrix.
- CLI tests should own command integration and output-file behavior.
- Prefer semantic assertions over snapshots.
- Every upstream case not ported should have a short comment in the test file
  or in the PR description explaining why it is TypeScript/ORM-only.

## Done Criteria

- [ ] Core SQL tests cover dialect x custom naming x plugin x field-type edges
  listed in Steps 2-4.
- [ ] CLI tests include at least four end-to-end generate/status cases from
  Step 5.
- [ ] Unsupported field types cannot silently generate text/string SQL.
- [ ] All commands in "Commands You Will Need" exit 0.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row for plan 002 is updated.

## STOP Conditions

Stop and report if:

- The Ruby schema layer intentionally treats omitted `required` differently
  from upstream and there is no documented adaptation.
- Implementing the passkey matrix requires adding a new dependency from core to
  `better_auth-passkey`.
- Fixing unsupported field types would break multiple existing tests in ways
  that look like public behavior.
- The executor cannot determine whether `generate_id` is supposed to affect SQL
  generation in Ruby.

## Maintenance Notes

When upstream CLI generator tests change, future parity work should update the
Ruby matrix by risk area, not by ORM output format. The stable Ruby contract is:
logical schema in core, SQL output by dialect, and CLI wiring that writes or
reports that output.
