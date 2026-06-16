# Plan 018: Complete CLI Test Parity And Remaining Command Coverage

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 2491497..HEAD -- packages/better_auth-cli packages/openauth-cli`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: LOW
- **Depends on**: `plans/016-cli-upstream-parity-inventory.md`,
  `plans/017-cli-init-and-strict-options.md`
- **Category**: tests
- **Planned at**: commit `2491497`, 2026-06-15

## Why This Matters

After plans 001–005 and 017, Ruby CLI still has a large test gap versus
upstream (~77 vs ~291 gross, ~120–150 Ruby-applicable cases uncovered). The
inventory from plan 016 must drive every remaining test port until all
`:partial` and `:todo` owners are `:covered`.

This plan splits the monolithic `cli_test.rb` (77 methods), ports upstream cases
by command, extends `info` for Ruby-relevant diagnostics, and adds optional
`upgrade` for Gemfile version bumps.

## Current State

Single test file:

```
packages/better_auth-cli/test/better_auth/cli_test.rb — 77 def test_ methods
```

Upstream test files (14) with Ruby applicability:

| Upstream file | Cases | Ruby target file | Target cases |
| --- | ---: | --- | ---: |
| `test/generate.test.ts` | 53 | `cli_generate_test.rb` | ~28 SQL-only |
| `test/migrate.test.ts` | 2 | `cli_migrate_test.rb` | 2 + status |
| `test/info.test.ts` | 7 | `cli_info_test.rb` | 10 |
| `test/get-config.test.ts` | 21 | `cli_config_resolution_test.rb` | ~12 |
| `test/init.test.ts` | 17 | `cli_init_test.rb` (017) | ~10 |
| `framework.test.ts` | 35 | `cli_framework_detect_test.rb` (017) | ~15 |
| `database.test.ts` | 11 | `cli_init_database_test.rb` | ~6 |
| `env.test.ts` | 19 | `cli_init_env_test.rb` | ~4 (`.env.example` only) |
| `auth-config.test.ts` | 4 | `cli_init_auth_config_test.rb` | 4 |
| `plugin.test.ts` | 66 | `cli_init_plugins_test.rb` | ~12 flags only |
| `cli_strict_options_test.rb` | — | (016/017) | ~8 |
| **Rejected** | ~77 | — | 0 |

**Target total**: **≥210** CLI tests, **0** inventory `:partial`/`:todo` for
Ruby-applicable upstream files.

### `info` gaps vs upstream

Upstream `info.test.ts` reports package manager, detected JS frameworks, database
clients from `package.json`. Ruby `info.rb` reports Ruby version, tables, doctor.

Extend JSON shape (additive only):

```json
{
  "framework": {"detected": "rails", "source": "gemfile"},
  "gems": {"better_auth": "0.10.0", "adapter": "better_auth-rails"},
  "bundler": {"version": "..."}
}
```

Only populate when `--cwd` project has `Gemfile`; omit keys when absent — do
not default to fake values.

### Optional: `upgrade` command

Upstream `upgrade.ts` bumps `better-auth` npm deps. Ruby equivalent:

```bash
better-auth upgrade --cwd PATH --yes
```

- Parse `Gemfile` / `Gemfile.lock` for `better_auth` and plugin gems
- Print planned version bumps (from rubygems.org API is **out of scope** — only
  suggest `bundle update better_auth` command in stdout)
- v1: **documentation command** that validates gems exist and prints exact
  `bundle update ...` line; no network

If network-free constraint blocks real upgrade, implement `upgrade` as guided
output only and mark inventory owner as `:covered` with note.

## Commands You Will Need

| Purpose | Command | Expected on success |
| --- | --- | --- |
| CLI tests | `cd packages/better_auth-cli && bundle exec rake test` | exit 0, ≥210 runs |
| Inventory | `bundle exec ruby -Itest -Ilib test/better_auth/cli_upstream_inventory_test.rb` | exit 0, no `:todo` |
| openauth | `cd packages/openauth-cli && bundle exec rake test` | exit 0 |
| Workspace CI | `bundle exec rake ci` | exit 0 |
| Lint | `bundle exec standardrb packages/better_auth-cli/lib packages/better_auth-cli/test` | exit 0 |

## Scope

**In scope**:

- Split `cli_test.rb` into topic files (see table above)
- `packages/better_auth-cli/lib/better_auth/cli/info.rb` — framework/gem detection
- `packages/better_auth-cli/lib/better_auth/cli/upgrade.rb` (new, optional)
- `packages/better_auth-cli/test/support/upstream_cli_parity.rb` — status updates
- `packages/openauth-cli/test/openauth/cli_test.rb` — alias coverage for new commands
- `packages/better_auth-cli/README.md`, `docs-site/content/docs/concepts/cli.mdx`

**Out of scope**:

- Porting Prisma/Drizzle/Kysely generate tests
- npm package manager tests
- `ai`, `mcp`, `login`, `logout`
- Real network calls in `upgrade`

## Git Workflow

- Branch: `feat/cli-test-parity`
- Commit message: `test(cli): complete upstream CLI parity matrix`
- Do not push unless instructed.

## Steps

### Step 1: Split existing cli_test.rb

Move tests into files without changing behavior:

- `cli_generate_test.rb`
- `cli_migrate_test.rb`
- `cli_doctor_test.rb`
- `cli_secret_test.rb`
- `cli_info_test.rb`
- `cli_mongo_test.rb`
- `cli_routing_test.rb` (help, unknown command)
- `cli_config_resolution_test.rb` (cwd, discover-config)

Keep thin `cli_test.rb` or remove if rake loader finds all `*_test.rb`.

Update every test invocation to include required `--cwd` and `--config` flags
per plan 017.

**Verify**: same test count as before split, all pass.

### Step 2: Port generate upstream cases

Read `reference/upstream-src/1.6.9/repository/packages/cli/test/generate.test.ts`.
Add Ruby tests for:

- All supported SQL dialects (sqlite, postgres, mysql, mssql)
- Plugin tables in output
- Custom model names / additional fields
- Unsupported field types → error
- Missing `--dialect`, `--output`, `--cwd`, `--config` → pretty errors
- `--discover-config` happy path
- No SQL when schema up to date (memory/sqlite)

Skip Prisma/Drizzle/Kysely/mock-adapter cases — mark inventory `:ruby_not_applicable`.

**Verify**: `cli_generate_test.rb` ≥28 tests pass.

### Step 3: Port migrate + config resolution cases

From `migrate.test.ts` and `get-config.test.ts`:

- `migrate --yes` applies schema
- Repeat migrate → no changes
- `migrate` without `--yes` → error
- Relative `--config` against `--cwd`
- `--discover-config` ordering deterministic
- Explicit config wins over discovered

**Verify**: `cli_migrate_test.rb` + `cli_config_resolution_test.rb` pass.

### Step 4: Extend info + port info.test.ts

Implement gemfile/framework detection in `info.rb` (read-only).

Port all 7 upstream `info.test.ts` scenarios adapted for Ruby:

- JSON without config (still valid with `--cwd` only)
- JSON with config — sanitized (no secret/password/token leakage)
- Human-readable output lines
- Plugin table names in `tables` array

Add 3 Ruby-specific tests: rails gem detection, no Gemfile → omit framework key.

**Verify**: `cli_info_test.rb` ≥10 tests pass.

### Step 5: Init plugin/env/auth-config test ports

Add focused init tests not covered in 017:

- `cli_init_env_test.rb`: writes `.env.example` not `.env` when `--write-env-example` passed; error when flag omitted and env needed
- `cli_init_auth_config_test.rb`: generated `config/better_auth.rb` includes `email_and_password`, `secret` placeholder comment (not auto secret)
- `cli_init_plugins_test.rb`: `--plugin two_factor` style flags append to generated config (static list from `BetterAuth::Plugins` registry)

Do not port upstream TypeScript import/path tests.

**Verify**: new init test files pass.

### Step 6: Optional upgrade command + tests

If implementing:

- `upgrade --cwd PATH` prints `bundle update better_auth better_auth-rails` based on Gemfile
- Requires `--yes` to do anything beyond dry-run print
- 3 tests: no Gemfile error, dry-run output, missing `--cwd` error

If skipping implementation, mark `upgrade` as `:ruby_not_applicable` in inventory
with note "use bundle update".

**Verify**: decision recorded in inventory.

### Step 7: Close inventory — all owners covered

Update `upstream_cli_parity.rb` so every Ruby-applicable upstream file is
`:covered`. Run inventory test.

**Verify**:

```bash
cd packages/better_auth-cli && bundle exec rake test 2>&1 | tail -3
# ≥210 runs, 0 failures

bundle exec ruby -Itest -Ilib test/better_auth/cli_upstream_inventory_test.rb
# exit 0
```

### Step 8: openauth alias + docs

Add openauth tests for `init`, strict-option error parity, `upgrade` if present.

Update README and docs with full command reference table.

## Test Plan

Total target breakdown:

| File | Tests |
| --- | ---: |
| cli_generate_test.rb | 28 |
| cli_migrate_test.rb | 12 |
| cli_doctor_test.rb | 14 |
| cli_info_test.rb | 10 |
| cli_config_resolution_test.rb | 12 |
| cli_init_* (4 files) | 25 |
| cli_framework_detect_test.rb | 15 |
| cli_strict_options_test.rb | 8 |
| cli_routing_test.rb | 10 |
| cli_secret_test.rb | 6 |
| cli_mongo_test.rb | 8 |
| cli_upgrade_test.rb | 3 |
| **Total** | **~151** new split + updated ≈ **≥210** |

## Done Criteria

- [ ] `bundle exec rake test` in `better_auth-cli` reports **≥210 runs**, 0 failures
- [ ] No Ruby-applicable upstream CLI test file remains `:todo` or `:partial` in inventory
- [ ] All existing plan 001–005 CLI behaviors still pass with strict flags
- [ ] `info --json` includes framework/gem detection when Gemfile present
- [ ] `openauth` alias tests cover `init` and strict errors
- [ ] Docs list every command with required flags
- [ ] `plans/README.md` plan 018 row DONE

## STOP Conditions

Stop and report if:

- Strict flag migration causes >50 test failures unrelated to missing flag updates
- Plugin init flags require loading every plugin gem in CLI process
- Inventory cannot reach `:covered` without network-dependent upgrade

## Maintenance Notes

When upstream CLI adds commands, update `upstream_cli_parity.rb` first (plan 016
pattern). New Ruby commands need inventory entry before implementation.

Test file split is permanent — do not re-monolith `cli_test.rb`.

## Findings Explicitly Rejected (record in plans/README.md)

| Upstream | Reason |
| --- | --- |
| `ai` | Agent/IDE Node wizard; no Ruby runtime equivalent |
| `mcp` | Cursor/Claude MCP config; out of Ruby CLI scope |
| `login` / `logout` | Delegates to npm `@better-auth/cli`; use Rubygems/bundler |
| Prisma/Drizzle/Kysely generate | Ruby is SQL-only per plan 002 |
| npm package manager detection | Ruby uses Bundler |
| Interactive prompts in init/migrate/generate | CI/non-interactive contract |
| Auto Next.js framework fallback | Wrong stack for Ruby port |
