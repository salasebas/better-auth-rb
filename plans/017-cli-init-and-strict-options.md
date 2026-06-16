# Plan 017: Add Init, Framework Detection, And Strict CLI Options

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 2491497..HEAD -- packages/better_auth-cli packages/openauth-cli docs-site/content/docs/concepts/cli.mdx`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: `plans/016-cli-upstream-parity-inventory.md`
- **Category**: direction
- **Planned at**: commit `2491497`, 2026-06-15

## Why This Matters

Upstream `init` scaffolds auth config, env, routes, and runs migrations
(`packages/cli/src/commands/init/index.ts`). Ruby has equivalent behavior split
across Rails/Hanami generators and Sinatra/Roda rake tasks, but no unified
`better-auth init` entry point.

The maintainer requires **no silent defaults**. Upstream falls back to Next.js
(`init/index.ts:583-585`), `process.cwd()`, and npm — all unacceptable for Ruby.

This plan adds a **non-interactive** `init` with explicit `--framework` or
`--detect-framework`, removes implicit CLI defaults, and keeps framework install
logic in existing packages (no duplication of generator templates in CLI).

## Current State

### Framework install entry points already in repo

| Framework | Entry | Path |
| --- | --- | --- |
| Rails | `rails generate better_auth:install` | `packages/better_auth-rails/lib/generators/better_auth/install/install_generator.rb:9-25` |
| Hanami | `InstallGenerator#run` | `packages/better_auth-hanami/lib/better_auth/hanami/generators/install_generator.rb:10-22` |
| Sinatra | `rake better_auth:install` | `packages/better_auth-sinatra/lib/better_auth/sinatra/tasks.rb:9-20` |
| Roda | `rake better_auth:install` | `packages/better_auth-roda/lib/better_auth/roda/tasks.rb:9-20` |
| Rack (generic) | none | Sinatra template is closest reference |

### CLI gem dependencies

`better_auth-cli.gemspec:27` — only `better_auth`. Do **not** add Rails/Hanami
as hard dependencies. Invoke framework tools via `bundle exec` in the target app.

### Upstream framework detection (reference only)

`packages/cli/src/commands/init/utility/framework.ts:8-48` — scans
`package.json` deps and config filenames. Ruby port scans **Gemfile** and
framework marker files only.

## Design: Init command (Ruby-specific)

### Invocation

```bash
# Explicit framework (recommended for CI)
better-auth init --cwd PATH --framework rails [--force]
better-auth init --cwd PATH --framework hanami|sinatra|roda|rack [--force]

# Detection opt-in (never implicit)
better-auth init --cwd PATH --detect-framework [--force]
```

### Required vs forbidden

- `--cwd` **required** (no `Dir.pwd` default)
- Exactly one of `--framework` or `--detect-framework` **required**
- Passing both → error: `Pass only one of --framework or --detect-framework`
- Passing neither → pretty error listing supported frameworks
- **No interactive prompts** in v1 (upstream uses `prompts`; Ruby CLI stays CI-safe)

### Framework detection rules (`--detect-framework`)

Implement `BetterAuth::CLI::FrameworkDetect.detect(cwd)` in
`packages/better_auth-cli/lib/better_auth/cli/framework_detect.rb`.

Detection order (first unique match wins; multiple matches → error):

| ID | Signals (all under `--cwd`) |
| --- | --- |
| `rails` | `config/application.rb` OR Gemfile contains `gem "rails"` OR `gem "better_auth-rails"` |
| `hanami` | `config/app.rb` + Hanami structure OR Gemfile `gem "hanami"` / `better_auth-hanami` |
| `sinatra` | Gemfile `gem "sinatra"` AND NOT `gem "roda"` |
| `roda` | Gemfile `gem "roda"` |
| `rack` | **never auto-detected** — must use `--framework rack` explicitly |

If zero matches:

```
Could not detect a supported Ruby framework under <cwd>.

Pass --framework rails|hanami|sinatra|roda|rack
```

If multiple matches (e.g. sinatra + rails gems):

```
Ambiguous framework detection: rails, sinatra.

Pass --framework <name> to choose explicitly.
```

**No Next.js fallback.** Unlike upstream `init/index.ts:583-585`.

### Init actions per framework

| Framework | Action |
| --- | --- |
| `rails` | Verify `Gemfile` lists `better_auth-rails`; run `bundle exec rails generate better_auth:install` in `--cwd`; propagate nonzero exit |
| `hanami` | Verify `better_auth-hanami` in Gemfile; run `bundle exec rake -f Rakefile better_auth:init` OR invoke `BetterAuth::Hanami::Generators::InstallGenerator.new(destination_root: cwd).run` via `bundle exec ruby -r...` if rake unavailable in test |
| `sinatra` | Verify `better_auth-sinatra`; run `bundle exec rake better_auth:install` |
| `roda` | Verify `better_auth-roda`; run `bundle exec rake better_auth:install` |
| `rack` | Write CLI-owned minimal scaffold (no new gem dep): `config/better_auth.rb` (memory adapter template), `db/better_auth/migrate/.keep`, stdout instructions for mount + `better-auth migrate` |

Use `--force` to overwrite only **CLI-owned** rack scaffold files; never
overwrite existing `config/initializers/better_auth.rb` or `config/better_auth.rb`
without `--force`, matching Rails generator skip behavior.

Optional flags (when provided, validate; when omitted, **do not invent values**):

- `--secret PATH_OR_VALUE` — if flag present without value → error
- `--base-url URL` — same
- `--database-dialect DIALECT` — for rack scaffold comments only in v1

Do **not** auto-generate secrets or default `http://localhost:3000` in files.

### Strict options for existing commands

Refactor `packages/better_auth-cli/lib/better_auth/cli.rb`:

1. Remove `options = {cwd: Dir.pwd}` default (`:267`). Require `--cwd`.
2. Replace implicit `resolve_config!` with:
   - `--config PATH` required unless `--discover-config` passed
   - `--discover-config` searches `CONFIG_PATHS` (plan 004 paths)
3. `generate`: require `--dialect`; remove `|| "postgres"` fallback (`:78`)
4. `info`: require `--cwd`; keep optional config (version-only JSON still valid)
5. Use `CLI::Errors.missing_option` for all missing-flag paths; include `Example:` line

Update `usage` string to show required flags with no bracket-implied defaults.

### Breaking change migration

Update README and docs: every example must include `--cwd` and `--config` (or
`--discover-config`). Plan 018 updates all tests.

## Commands You Will Need

| Purpose | Command | Expected on success |
| --- | --- | --- |
| CLI tests | `cd packages/better_auth-cli && bundle exec rake test` | exit 0 |
| openauth tests | `cd packages/openauth-cli && bundle exec rake test` | exit 0 |
| Workspace CI | `bundle exec rake ci` | exit 0 |
| Lint | `bundle exec standardrb packages/better_auth-cli/lib packages/better_auth-cli/test` | exit 0 |

## Scope

**In scope**:

- `packages/better_auth-cli/lib/better_auth/cli.rb`
- `packages/better_auth-cli/lib/better_auth/cli/errors.rb`
- `packages/better_auth-cli/lib/better_auth/cli/framework_detect.rb` (new)
- `packages/better_auth-cli/lib/better_auth/cli/init.rb` (new)
- `packages/better_auth-cli/lib/better_auth/cli/rack_scaffold.rb` (new)
- `packages/better_auth-cli/test/better_auth/cli_init_test.rb` (new)
- `packages/better_auth-cli/test/better_auth/cli_framework_detect_test.rb` (new)
- `packages/better_auth-cli/test/better_auth/cli_strict_options_test.rb`
- `packages/better_auth-cli/test/support/cli_helpers.rb` (command runner injection)
- `packages/better_auth-cli/README.md`
- `docs-site/content/docs/concepts/cli.mdx`

**Out of scope**:

- Interactive wizard / prompts
- `ai`, `mcp`, `login`, `logout` commands
- `upgrade` command (plan 018 optional)
- Rewriting entire `cli_test.rb` (plan 018)
- Adding framework gems to `better_auth-cli.gemspec`

## Git Workflow

- Branch: `feat/cli-init-strict-options`
- Commit message: `feat(cli): add init and require explicit options`
- Do not push unless instructed.

## Steps

### Step 1: Implement framework detection module

Create `framework_detect.rb` with `detect(cwd) -> {framework:, ambiguous: []}`.
Pure filesystem + Gemfile parse (regex `gem ["']name["']` is enough; no new gems).

Port test ideas from upstream `framework.test.ts` for **Ruby frameworks only**
(~15 cases): rails detected, hanami detected, sinatra, roda, null, ambiguous.

**Verify**: `bundle exec ruby -Itest -Ilib test/better_auth/cli_framework_detect_test.rb` → exit 0.

### Step 2: Implement rack scaffold + init runner

`rack_scaffold.rb` writes minimal `config/better_auth.rb` using pattern from
`packages/better_auth-sinatra/lib/better_auth/sinatra/tasks.rb:10-19` but with
`:memory` adapter and comments pointing to `better-auth doctor`.

`init.rb` dispatches by framework; inject `command_runner:` callable for tests
(default `Open3.capture3`).

**Verify**: init tests with mocked command runner pass for rack scaffold path.

### Step 3: Wire `init` into CLI router

Add `when "init"` branch; parse options; call `CLI::Init.run`.

**Verify**: `run_cli("init")` → error mentioning `--cwd` and framework flags.

### Step 4: Enforce strict options on existing commands

Implement `--discover-config`; require `--cwd` everywhere; require `--dialect`
on generate; update all option parsers.

Enable strict tests from plan 016 (remove skips).

**Verify**: `cli_strict_options_test.rb` → exit 0.

### Step 5: Framework init integration tests (mocked)

`cli_init_test.rb` minimum cases:

1. `init --cwd DIR --framework rack` creates `config/better_auth.rb`
2. `init --cwd DIR --framework rack` skips existing config without `--force`
3. `init --cwd DIR --detect-framework` on Rails-like tree picks `rails`
4. Ambiguous Gemfile → error lists frameworks
5. `init --cwd DIR --framework rails` without gem in Gemfile → pretty error
6. Mocked `bundle exec rails generate` success prints created files
7. Executable smoke: `better-auth init --help` lists flags

**Verify**: `cd packages/better_auth-cli && bundle exec rake test` → exit 0.

### Step 6: Update docs

Document init, strict flags, `--discover-config`, and breaking changes in README
and `cli.mdx`.

**Verify**: lint + tests exit 0.

## Test Plan

- Framework detect: ~15 tests (upstream `framework.test.ts` Ruby subset)
- Init: ~10 tests (upstream `init.test.ts` non-interactive subset)
- Strict options: ~8 tests
- Use `cli_helpers.rb` `run_cli` and new `with_cli_command_runner` stub

## Done Criteria

- [ ] `better-auth init --cwd PATH --framework rack` scaffolds config
- [ ] `better-auth init --cwd PATH --detect-framework` works with explicit opt-in
- [ ] Ambiguous/multi-framework detection errors are pretty and actionable
- [ ] All config-backed commands require `--cwd`
- [ ] `--config` required unless `--discover-config` passed
- [ ] `generate` requires `--dialect` (no postgres fallback)
- [ ] `cli_strict_options_test.rb` and init/framework tests pass
- [ ] Docs updated; `plans/README.md` row DONE

## STOP Conditions

Stop and report if:

- Invoking Rails/Hanami generators requires adding framework gems to CLI gemspec
- Real `bundle exec rails generate` needed in CI (use mocks in unit tests)
- Existing apps depend on implicit discovery and mass test update exceeds plan 018 scope — report scale

## Maintenance Notes

Framework packages own templates; CLI only orchestrates. When Rails install
generator changes, init tests with mocked runner still pass; add one integration
smoke in `better_auth-rails` if needed.

`rack` is explicit-only by design — document why in `framework_detect.rb` comment.
