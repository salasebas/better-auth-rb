# Plan 016: Establish CLI Upstream Parity Inventory And Strict Options Contract

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
- **Effort**: M
- **Risk**: MED (breaking CLI UX from plan 004 implicit discovery)
- **Depends on**: `plans/001-cli-command-contract-characterization.md`,
  `plans/005-cli-secret-info-json.md`
- **Category**: tests
- **Planned at**: commit `2491497`, 2026-06-15

## Why This Matters

Ruby CLI has **77** tests; upstream `packages/cli` has **~291** cases across
14 files. There is no CLI parity inventory (unlike core server parity in plan
006). The maintainer also requires **no implicit defaults**: every config-backed
command must receive explicit flags or return a multi-line, actionable error.

Plan 004 introduced optional config discovery when `--config` is omitted. That
conflicts with the new contract. This plan establishes the inventory, error
format, and explicit-flag rules that plans 017–018 build on.

## Current State

Upstream commands (`reference/upstream-src/1.6.9/repository/packages/cli/src/index.ts:33-43`):

```
ai, init, migrate, generate, secret, info, login, logout, mcp, upgrade
```

Ruby commands (`packages/better_auth-cli/lib/better_auth/cli.rb:48-66`):

```
generate, migrate, migrate status, doctor, secret, info, mongo indexes, help
```

### Implicit defaults to remove (plan 017 implements; this plan defines contract)

```ruby
# packages/better_auth-cli/lib/better_auth/cli.rb:267
options = {cwd: Dir.pwd}

# packages/better_auth-cli/lib/better_auth/cli.rb:78
dialect = ... || adapter&.dialect || "postgres"

# packages/better_auth-cli/lib/better_auth/cli.rb:281-292
# resolve_config! auto-discovers when --config omitted
```

### Gap summary (Ruby-applicable upstream surface)

| Upstream area | Upstream cases | Ruby today | Gap |
| --- | ---: | ---: | --- |
| `generate` SQL paths | ~30 | ~16 | dialect/output strictness, adapter errors |
| `migrate` | 2 | ~6 | already ahead; keep `--yes` requirement |
| `init` + utilities | ~145 | 0 | full initiative in plan 017 |
| `get-config` / paths | ~10 | ~9 cwd tests | explicit `--discover-config` |
| `info` | 7 | 6 | framework/gemfile detection in plan 018 |
| `framework` detect | ~35 | 0 | Ruby frameworks only in plan 017 |
| Strict option errors | 0 | 0 | new contract tests in this plan |
| **Rejected** Prisma/Drizzle/Kysely codegen | ~65 | — | out of scope |
| **Rejected** npm PM / install-deps | ~27 | — | out of scope |
| **Rejected** `ai`, `mcp`, `login`, `logout` | 0 tested | — | Node-only |

Target after plans 016–018: **~210–230** Ruby CLI tests covering **100% of
Ruby-applicable upstream CLI behavior** (not literal 291).

## Commands You Will Need

| Purpose | Command | Expected on success |
| --- | --- | --- |
| CLI tests | `cd packages/better_auth-cli && bundle exec rake test` | exit 0 |
| Alias CLI tests | `cd packages/openauth-cli && bundle exec rake test` | exit 0 |
| Ruby lint | `bundle exec standardrb packages/better_auth-cli/lib packages/better_auth-cli/test packages/openauth-cli/test` | exit 0 |

## Scope

**In scope**:

- `packages/better_auth-cli/test/support/upstream_cli_parity.rb` (new)
- `packages/better_auth-cli/test/better_auth/cli_upstream_inventory_test.rb` (new)
- `packages/better_auth-cli/lib/better_auth/cli/errors.rb` (new — pretty errors)
- `packages/better_auth-cli/lib/better_auth/cli.rb` (contract hooks only; full flag changes land in 017)
- `packages/better_auth-cli/test/better_auth/cli_strict_options_test.rb` (new)
- `plans/README.md`

**Out of scope**:

- `init` implementation (plan 017)
- Rewriting all existing tests (plan 018)
- Adding Rails/Hanami as runtime dependencies of `better_auth-cli`
- Porting `ai`, `mcp`, `login`, `logout`

## Git Workflow

- Branch: `feat/cli-parity-inventory`
- Commit message style: `test(cli): add upstream CLI parity inventory`
- Do not push unless instructed.

## Steps

### Step 1: Add upstream CLI parity inventory module

Create `packages/better_auth-cli/test/support/upstream_cli_parity.rb` modeled
after `packages/better_auth/test/support/upstream_server_parity.rb`.

Constants:

- `UPSTREAM_ROOT` → `reference/upstream-src/1.6.9/repository/packages/cli`
- `EXCLUDED_UPSTREAM_TESTS` — map file → reason. Minimum entries:
  - `test/generate-all-db.test.ts` — Prisma/Drizzle/Kysely codegen
  - `test/install-dependencies.test.ts` — npm/yarn/pnpm/bun installers
  - `test/check-package-managers.test.ts` — Node package managers
  - `src/commands/init/utility/imports.test.ts` — TypeScript import paths
  - Any test file whose sole subject is Next.js/Astro/Nuxt/Svelte client wiring
- `RUBY_CLI_TEST_OWNERS` — map upstream test file → Ruby owner test file(s),
  status (`:covered`, `:partial`, `:todo`, `:ruby_not_applicable`), plan number,
  notes.

Include every `*.test.ts` under upstream `packages/cli/` (14 files, ~291 cases).

Add inventory test `cli_upstream_inventory_test.rb`:

- Every upstream test file is classified or excluded with a reason
- No stale inventory entries
- Owner paths exist for `:covered`/`:partial`/`:todo` entries

**Verify**: `cd packages/better_auth-cli && bundle exec ruby -Itest -Ilib test/better_auth/cli_upstream_inventory_test.rb` → exit 0.

### Step 2: Define explicit-options contract document in code

Add `packages/better_auth-cli/lib/better_auth/cli/errors.rb`:

```ruby
module BetterAuth
  class CLI
    module Errors
      def self.missing_option(command, flag, hint_lines = [])
        lines = ["#{command} requires #{flag}."]
        lines.concat(hint_lines)
        lines.join("\n")
      end
    end
  end
end
```

Document the contract in a module comment (not a new markdown file):

| Command | Required flags | Optional flags |
| --- | --- | --- |
| `generate` | `--cwd`, `--config`, `--dialect`, `--output` | `--discover-config` replaces omitted `--config` |
| `migrate` | `--cwd`, `--config`, `--yes` | `--discover-config` |
| `migrate status` | `--cwd`, `--config` | `--discover-config` |
| `doctor` | `--cwd`, `--config` | `--json`, `--discover-config` |
| `info` | `--cwd` | `--config`, `--json`, `--discover-config` |
| `mongo indexes` | `--cwd`, `--config` | `--discover-config` |
| `secret` | none | `--raw` |
| `init` (plan 017) | `--cwd`, (`--framework` XOR `--detect-framework`) | `--force`, `--secret`, `--base-url`, `--database-dialect` |

**Key rule**: omitting `--cwd` is always an error. Omitting `--config` is an
error unless `--discover-config` is passed.

**Verify**: file loads via `require "better_auth/cli/errors"` without error.

### Step 3: Add failing strict-option tests (red phase)

Create `cli_strict_options_test.rb` asserting current gaps, to be fixed in plan
017. Tests should expect these errors once 017 lands; for this plan, either:

- skip with message `TODO plan 017`, OR
- mark as pending documenting expected messages

Preferred: write tests with the **target** messages and leave them failing/skipped
with explicit `skip "plan 017"` until 017 completes. Inventory and error helper
must still pass.

Target cases (minimum):

1. `doctor` with no flags → error mentions `--cwd` and `--config`
2. `generate` without `--dialect` → error mentions `--dialect`
3. `generate` without `--cwd` → error mentions `--cwd`
4. `migrate` without `--cwd` → error mentions `--cwd`
5. Error output is multi-line and includes an `Example:` line

**Verify**: inventory test passes; strict tests are skipped or documented.

### Step 4: Update plans index

Mark plan 016 TODO → IN PROGRESS → DONE when complete.

**Verify**: `plans/README.md` lists 016–018 CLI parity initiative.

## Test Plan

- Inventory test locks upstream file list (14 files) and prevents unclassified drift.
- Strict-option tests document the explicit-flag contract for plan 017.
- Pattern: mirror `packages/better_auth/test/better_auth/upstream_server_parity_inventory_test.rb`.

## Done Criteria

- [ ] `upstream_cli_parity.rb` exists with excluded + owner maps for all 14 upstream CLI test files
- [ ] `cli_upstream_inventory_test.rb` passes
- [ ] `cli/errors.rb` defines pretty missing-option helper
- [ ] Strict-option test file exists documenting required flags
- [ ] `plans/README.md` updated with 016–018 initiative
- [ ] Lint and inventory tests exit 0

## STOP Conditions

Stop and report if:

- Upstream CLI test file count differs from 14 — refresh inventory before proceeding.
- Implementing strict flags in this plan (belongs in 017).
- Adding new gem dependencies to `better_auth-cli`.

## Maintenance Notes

Plan 017 will break tests that rely on implicit `--cwd` and config discovery.
Update `cli_test.rb` in plan 018, not here. Reviewers should treat
`--discover-config` as an explicit opt-in replacement for plan 004's implicit
discovery.
