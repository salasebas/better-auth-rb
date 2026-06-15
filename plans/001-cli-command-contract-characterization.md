# Plan 001: Lock Down Current CLI Command Contracts

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 7920aee..HEAD -- packages/better_auth-cli packages/openauth-cli .github/workflows/ci.yml`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `7920aee`, 2026-06-14

## Why This Matters

The CLI is a published executable surface. The current tests exercise useful
in-process behavior, but they do not fully lock down command routing, help
output, executable invocation, alias parity, config eval failures, or the
stdout/stderr/status contract. Those tests should exist before adding more
feature tests so later work can rely on stable helpers.

## Current State

Relevant files:

- `packages/better_auth-cli/lib/better_auth/cli.rb` - command routing,
  option parsing, config loading, and process-safe return codes.
- `packages/better_auth-cli/test/better_auth/cli_test.rb` - current Minitest
  suite for in-process `BetterAuth::CLI.run`.
- `packages/better_auth-cli/test/support/cli_helpers.rb` - current test
  helpers and fake adapters.
- `packages/openauth-cli/test/openauth/cli_test.rb` - alias package executable
  smoke tests.

Current command runner and rescue contract:

```ruby
# packages/better_auth-cli/lib/better_auth/cli.rb:21
def run(argv = ARGV, stdout: $stdout, stderr: $stderr)
  new(argv, stdout: stdout, stderr: stderr).run
rescue Error, BetterAuth::SQLMigration::UnsupportedAdapterError, BetterAuth::Error, OptionParser::ParseError => error
  stderr.puts error.message
  1
end
```

Current config loading can execute arbitrary config code and currently lets
unexpected exceptions escape:

```ruby
# packages/better_auth-cli/lib/better_auth/cli.rb:186
def load_config(path)
  raise Error, "Config file not found: #{path}" unless File.exist?(path)

  self.class.configure(nil)
  result = TOPLEVEL_BINDING.eval(File.read(path), path)
  value = normalize_config_value(result) || self.class.configuration
  raise Error, "Config file must return a Hash, BetterAuth::Configuration, or BetterAuth::Auth" unless value
```

Current tests use only the in-process helper for `better_auth-cli`:

```ruby
# packages/better_auth-cli/test/support/cli_helpers.rb:46
def run_cli(*argv)
  stdout = StringIO.new
  stderr = StringIO.new
  status = BetterAuth::CLI.run(argv, stdout: stdout, stderr: stderr)
  [status, stdout.string, stderr.string]
end
```

The `openauth-cli` package already has executable coverage that `better_auth-cli`
does not mirror:

```ruby
# packages/openauth-cli/test/openauth/cli_test.rb:34
stdout, stderr, status = Open3.capture3(
  {"RUBYLIB" => ruby_lib},
  RbConfig.ruby,
  File.expand_path("../../exe/openauth", __dir__),
  "generate",
```

Repo conventions to match:

- Ruby files use `# frozen_string_literal: true`.
- Tests use Minitest in CLI/core packages.
- Prefer real temp directories and observable filesystem/database effects over
  mocks.
- Keep the CLI dependency-light; do not add dependencies.

## Ruby Schema & Migration Context

This plan does **not** implement migration SQL. Executors still need this
context so CLI characterization tests use realistic config fixtures.

- Schema for `generate`, `migrate`, `migrate status`, and `doctor` all derive
  from the same eval'd config: `plugins:` array + `user`/`session`/
  `additional_fields` options.
- A config file that omits a plugin from `plugins:` will produce incomplete
  schema in later plans (002/003). Characterization fixtures should include
  representative `plugins:` when testing commands that load config.
- SQL inline migrate (`migrate --yes`) is the only auto-apply path in this
  CLI; framework generators (Rails AR, Hanami Sequel, Sinatra/Roda/Grape `.sql`)
  are separate entry points sharing `BetterAuth::SQLMigration.plan`.
- MongoDB index setup is `mongo indexes`, not covered here.

See plans 002 and 003 for full schema generation and migration hardening.

## Commands You Will Need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| CLI tests | `cd packages/better_auth-cli && bundle exec rake test` | exit 0, all tests pass |
| Alias CLI tests | `cd packages/openauth-cli && bundle exec rake test` | exit 0, all tests pass |
| Lint touched packages | `bundle exec standardrb packages/better_auth-cli/Rakefile packages/better_auth-cli/lib packages/better_auth-cli/test packages/openauth-cli/lib packages/openauth-cli/test` | exit 0, no offenses |

## Scope

**In scope**:

- `packages/better_auth-cli/test/better_auth/cli_test.rb`
- `packages/better_auth-cli/test/support/cli_helpers.rb`
- `packages/better_auth-cli/lib/better_auth/cli.rb` only if a new test exposes
  a real current bug in the command contract.
- `packages/openauth-cli/test/openauth/cli_test.rb` for alias parity tests.

**Out of scope**:

- New commands or feature behavior. This plan characterizes existing commands.
- Core migration SQL behavior. Leave that to plans 002 and 003.
- New runtime or development dependencies.
- Docs updates unless a test exposes a documented command that is currently
  impossible to run.

## Git Workflow

- Branch: `test/cli-command-contracts`
- Commit message style: `test(cli): lock down CLI command contracts`
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Add executable helpers for `better-auth`

Extend `packages/better_auth-cli/test/support/cli_helpers.rb` with a helper
similar to `openauth-cli`'s existing `Open3.capture3` setup. It should:

- Build `RUBYLIB` from `packages/better_auth-cli/lib` and
  `packages/better_auth/lib`.
- Execute `packages/better_auth-cli/exe/better-auth` through `RbConfig.ruby`.
- Return `[stdout, stderr, status]`.

Keep the existing `run_cli` helper because most tests should stay in-process.

**Verify**: `cd packages/better_auth-cli && bundle exec rake test` -> exit 0.

### Step 2: Cover global help and command routing

Add tests in `packages/better_auth-cli/test/better_auth/cli_test.rb` for:

- `run_cli` with no args returns status 0 and includes all current commands:
  `generate`, `migrate`, `migrate status`, `doctor`, and `mongo indexes`.
- `run_cli("help")`, `run_cli("--help")`, and `run_cli("-h")` return status 0
  and the same usage text.
- Unknown top-level command still returns status 1 and writes only stderr.
- Unknown `mongo` subcommand with no subcommand prints
  `Unknown mongo command: (none)`.

Do not change command output strings unless a test proves a real bug.

**Verify**: `cd packages/better_auth-cli && bundle exec rake test` -> exit 0.

### Step 3: Cover executable behavior for `better-auth`

Add executable tests that run `exe/better-auth` directly:

- `better-auth --help` succeeds and prints the same usage.
- `better-auth generate --config <tmp config> --dialect sqlite --output <tmp file>`
  succeeds and writes a SQL file containing `CREATE TABLE IF NOT EXISTS "users"`.
- `better-auth wat` exits non-zero and prints `Unknown command: wat` to stderr.

Use temp dirs and the helper from Step 1.

**Verify**: `cd packages/better_auth-cli && bundle exec rake test` -> exit 0.

### Step 4: Characterize config loading failures and state isolation

Add tests for the config-loading boundary:

- A config file that raises `RuntimeError, "boom"` should return status 1 and
  print a concise message without a Ruby backtrace. If this currently fails,
  update `CLI.run` to rescue `StandardError` only around `load_config` or wrap
  config eval failures in `CLI::Error`. Do not swallow `SystemExit` or
  `SignalException`.
- A config file that calls `BetterAuth::CLI.configure` must not leak into the
  next config load. There is already teardown cleanup; this test should create
  one config using `configure`, then another invalid config, and assert the
  invalid config does not reuse stale state.
- Config returning `nil` without `CLI.configure` keeps the existing allowed
  types error.

**Verify**: `cd packages/better_auth-cli && bundle exec rake test` -> exit 0.

### Step 5: Add alias parity for `openauth`

In `packages/openauth-cli/test/openauth/cli_test.rb`, add tests that the
`openauth` executable:

- Prints help for `--help`.
- Returns a non-zero status and the same stderr message for an unknown command.

Do not duplicate every `better_auth-cli` test in the alias package. The alias
package should prove executable packaging and command delegation only.

**Verify**: `cd packages/openauth-cli && bundle exec rake test` -> exit 0.

### Step 6: Run lint

Run StandardRB on the touched CLI files.

**Verify**:
`bundle exec standardrb packages/better_auth-cli/Rakefile packages/better_auth-cli/lib packages/better_auth-cli/test packages/openauth-cli/lib packages/openauth-cli/test`
-> exit 0.

## Test Plan

- Add Minitest examples in the existing `BetterAuthCLITest` class.
- Reuse `Dir.mktmpdir`, `StringIO`, `Open3.capture3`, and `RbConfig.ruby`.
- Keep tests focused on status, stdout, stderr, and filesystem side effects.
- Do not assert exact full usage text; assert the presence of command lines so
  harmless whitespace changes do not cause churn.

## Done Criteria

- [ ] `cd packages/better_auth-cli && bundle exec rake test` exits 0.
- [ ] `cd packages/openauth-cli && bundle exec rake test` exits 0.
- [ ] StandardRB command from Step 6 exits 0.
- [ ] `better-auth` executable has direct help, success, and failure tests.
- [ ] `openauth` executable has help and failure delegation tests.
- [ ] Config eval errors return status 1 without a backtrace.
- [ ] `plans/README.md` status row for plan 001 is updated.

## STOP Conditions

Stop and report if:

- The CLI command list changed substantially since this plan was written.
- Handling config eval failures requires changing public config file semantics.
- A test needs a new gem dependency.
- Executable tests cannot run through `RbConfig.ruby` in the package test
  environment.

## Maintenance Notes

Future CLI commands should add both in-process command tests and, when the
command affects packaging or process behavior, one executable smoke test. Keep
alias package tests intentionally thin; they should prove delegation, not
duplicate implementation coverage.
