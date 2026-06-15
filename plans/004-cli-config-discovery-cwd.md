# Plan 004: Add Config Discovery And `--cwd` Support

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 7920aee..HEAD -- packages/better_auth-cli packages/openauth-cli docs-site/content/docs/concepts/cli.mdx docs-site/content/docs/concepts/database.mdx`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/001-cli-command-contract-characterization.md`
- **Category**: dx
- **Planned at**: commit `7920aee`, 2026-06-14

## Why This Matters

The current Ruby CLI requires `--config` for every command. Upstream CLI lets
users run from a project directory using `--cwd` and optional config discovery.
Ruby users should be able to run `better-auth doctor`, `better-auth generate`,
and `better-auth migrate status` from a project root when a conventional Ruby
config path exists.

## Current State

The CLI currently requires config explicitly:

```ruby
# packages/better_auth-cli/lib/better_auth/cli.rb:151
def parse_generate_options(args)
  options = {}
  OptionParser.new do |parser|
    parser.on("--config PATH") { |value| options[:config] = value }
    parser.on("--dialect DIALECT") { |value| options[:dialect] = value }
    parser.on("--output PATH") { |value| options[:output] = value }
  end.parse!(args)
  require_option!(options, :config, "generate --config PATH is required")
```

`migrate` and `doctor` use the same explicit-only pattern:

```ruby
# packages/better_auth-cli/lib/better_auth/cli.rb:163
parser.on("--config PATH") { |value| options[:config] = value }

# packages/better_auth-cli/lib/better_auth/cli.rb:173
parser.on("--config PATH") { |value| options[:config] = value }
```

Upstream generate/migrate support `--cwd` and describe optional config:

```ts
// reference/upstream-src/1.6.9/repository/packages/cli/src/commands/generate.ts:267
export const generate = new Command("generate")
  .option("-c, --cwd <cwd>", "the working directory. defaults to the current directory.", process.cwd())
  .option("--config <config>", "the path to the configuration file. defaults to the first configuration file found.")
```

Ruby docs still show manual config inspection and no CLI discovery:

```md
<!-- docs-site/content/docs/concepts/cli.mdx:101 -->
Custom config path:

```ruby
require_relative "../config/auth"
```
```

## Ruby Schema & Migration Context

Config discovery affects every command that loads `config/better_auth.rb` (or
equivalent). The discovered file must contain the **full** auth configuration,
not just database URL and secret.

**What discovery must preserve for migrations**

- `plugins:` array — each plugin's `schema` contributes tables/columns to
  `BetterAuth::Schema.auth_tables`.
- `user` / `session` / `account` / `verification` blocks with
  `additional_fields` — merged into core tables at plan time.
- `BetterAuth::Plugins.additional_fields(...)` in `plugins:` — same effect as
  inline `additional_fields` on options.

If `--cwd` points at a subdirectory, the config file found there must still
declare all plugins the app uses. Otherwise `generate` / `migrate status` /
`doctor` will under-report pending work compared to production.

**SQL-only migrate path**

- Discovered config with `database: {adapter: "postgres"}` (etc.) enables
  `SQLMigration.plan` against a live connection.
- Mongo adapter configs use `mongo indexes`; do not expect SQL migrate tests
  to pass against Mongo-only configs.

## Commands You Will Need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| CLI tests | `cd packages/better_auth-cli && bundle exec rake test` | exit 0 |
| Alias CLI tests | `cd packages/openauth-cli && bundle exec rake test` | exit 0 |
| Docs lint/build check | `cd docs-site && pnpm lint` | exit 0 if docs-site deps are installed; otherwise document why skipped |
| Ruby lint | `bundle exec standardrb packages/better_auth-cli/lib packages/better_auth-cli/test packages/openauth-cli/test` | exit 0 |

## Scope

**In scope**:

- `packages/better_auth-cli/lib/better_auth/cli.rb`
- `packages/better_auth-cli/test/better_auth/cli_test.rb`
- `packages/better_auth-cli/test/support/cli_helpers.rb`
- `packages/openauth-cli/test/openauth/cli_test.rb`
- `packages/better_auth-cli/README.md`
- `packages/openauth-cli/README.md`
- `docs-site/content/docs/concepts/cli.mdx`
- `docs-site/content/docs/concepts/database.mdx` if it references old CLI usage.

**Out of scope**:

- Rails generator changes.
- A full `init` command.
- Prompting for missing config.
- Loading TypeScript/JavaScript configs.

## Git Workflow

- Branch: `feat/cli-config-discovery`
- Commit message style: `feat(cli): add config discovery and cwd support`
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Define Ruby config discovery paths

Add a private constant in `BetterAuth::CLI`, for example:

```ruby
CONFIG_PATHS = [
  "config/better_auth.rb",
  "config/auth.rb",
  "better_auth.rb",
  "auth.rb"
].freeze
```

Do not include Rails initializers by default unless they are safe to eval
without a Rails app boot. If you believe `config/initializers/better_auth.rb`
should be included, STOP and report because it may require Rails constants.

**Verify**: `cd packages/better_auth-cli && bundle exec rake test` -> exit 0.

### Step 2: Add `--cwd` parsing to config-backed commands

Add `--cwd PATH` to `generate`, `migrate`, `migrate status`, `doctor`, and
`mongo indexes`.

Behavior:

- Default cwd is `Dir.pwd`.
- If `--cwd` does not exist or is not a directory, return status 1 with a clear
  stderr message.
- If `--config` is relative, resolve it relative to `--cwd`.
- If `--config` is absolute, use it as-is.
- If `--config` is omitted, find the first existing path from `CONFIG_PATHS`
  under `--cwd`.
- If no config is found, return status 1 with a message that lists the searched
  paths and says `pass --config PATH`.

Keep `generate --output` behavior unchanged for this step unless Step 3 changes
it explicitly.

**Verify**: `cd packages/better_auth-cli && bundle exec rake test` -> exit 0.

### Step 3: Decide and test output path resolution

Use this contract unless it conflicts with existing tests:

- Relative `--output` paths resolve relative to `--cwd`.
- Absolute `--output` paths stay absolute.

Add tests for both. This matches the user expectation that all command paths
are project-root relative after `--cwd` is introduced.

If preserving current `Dir.pwd` relative output behavior is required, STOP and
report because that makes `--cwd` only partial.

**Verify**: `cd packages/better_auth-cli && bundle exec rake test` -> exit 0.

### Step 4: Add discovery tests for all commands

Add tests that create temp projects with `config/better_auth.rb` and run:

- `generate --cwd <dir> --dialect sqlite --output db/auth.sql`
- `migrate --cwd <dir> --yes`
- `migrate status --cwd <dir>`
- `doctor --cwd <dir>`
- `mongo indexes --cwd <dir>` with a Mongo fake config.

Also add tests for:

- Explicit `--config` wins over discovered config.
- Relative `--config` resolves against `--cwd`.
- Missing `--cwd` directory is an error.
- No discovered config is an error listing searched paths.

**Verify**: `cd packages/better_auth-cli && bundle exec rake test` -> exit 0.

### Step 5: Add alias coverage

Add `openauth` executable tests that prove `--cwd` and config discovery are
delegated correctly for one command, preferably `doctor` or `generate`.

**Verify**: `cd packages/openauth-cli && bundle exec rake test` -> exit 0.

### Step 6: Update CLI docs

Update package READMEs and docs-site:

- Show `better-auth generate --cwd . --dialect postgres --output ...` as an
  option, but keep explicit `--config` examples.
- List discovery paths.
- Explain that non-Rails Rack apps can use `better-auth generate`, `migrate
  status`, `migrate --yes`, and `doctor` with a Ruby config file.
- Update `openauth-cli` README with the same path semantics.

Do not imply Rails initializers are auto-loaded unless Step 1 included them.

**Verify**:
`cd docs-site && pnpm lint` -> exit 0 if docs-site deps are installed; if deps
are unavailable, record the skip in the final response.

### Step 7: Run lint

**Verify**:
`bundle exec standardrb packages/better_auth-cli/lib packages/better_auth-cli/test packages/openauth-cli/test`
-> exit 0.

## Test Plan

- Use temp directories to model project roots.
- Assert resolved output files are created under `--cwd`.
- Assert discovered config path ordering is deterministic.
- Assert error messages do not expose config contents.

## Done Criteria

- [ ] `generate`, `migrate`, `migrate status`, `doctor`, and `mongo indexes`
  accept `--cwd`.
- [ ] Relative `--config` and `--output` paths resolve against `--cwd`.
- [ ] Omitted `--config` discovers conventional Ruby config paths.
- [ ] Missing config errors list searched paths.
- [ ] Package README and docs-site CLI docs describe the behavior.
- [ ] All required Ruby tests and lint commands exit 0.
- [ ] `plans/README.md` status row for plan 004 is updated.

## STOP Conditions

Stop and report if:

- Supporting discovery requires evaluating Rails initializers outside Rails.
- Existing tests or docs depend on relative `--output` paths resolving against
  process cwd.
- Config discovery introduces ambiguity between two existing config files that
  cannot be resolved by deterministic ordering.
- Docs-site dependencies are missing and cannot be checked without installing.

## Maintenance Notes

All future config-backed commands should use one shared resolver so `--cwd`,
relative path, discovery, and error messages stay consistent. Reviewers should
look for duplicate path-resolution logic.
