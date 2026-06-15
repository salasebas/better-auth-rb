# Plan 005: Add Secret Generation And JSON Diagnostics

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 7920aee..HEAD -- packages/better_auth-cli packages/openauth-cli packages/better_auth/lib/better_auth/doctor.rb docs-site/content/docs/concepts/cli.mdx docs-site/content/docs/installation.mdx`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: `plans/001-cli-command-contract-characterization.md`,
  `plans/004-cli-config-discovery-cwd.md`
- **Category**: direction
- **Planned at**: commit `7920aee`, 2026-06-14

## Why This Matters

Upstream CLI includes `secret` and `info`; Ruby docs currently tell users to run
manual shell snippets and inspect Ruby objects. A Ruby-native `secret` command
and sanitized JSON diagnostics would reduce setup mistakes and make support/CI
diagnostics safer without bringing in Node-specific package manager behavior.

## Current State

Current Ruby CLI commands:

```ruby
# packages/better_auth-cli/lib/better_auth/cli.rb:35
case command
when "generate"
when "migrate"
when "doctor"
when "mongo"
when "-h", "--help", "help", nil
```

Current docs use manual commands:

```md
<!-- docs-site/content/docs/concepts/cli.mdx:113 -->
## Secret

Use a strong secret for token signing and encrypted cookies.

```bash
ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'
```
```

Current doctor result is structured internally but prints text only:

```ruby
# packages/better_auth/lib/better_auth/doctor.rb:7
Result = Struct.new(:ok, :warnings, :errors, keyword_init: true) do
  def success?
    errors.empty?
  end
end
```

Upstream registers `secret` and `info`:

```ts
// reference/upstream-src/1.6.9/repository/packages/cli/src/index.ts:33
program
  .addCommand(generateSecret)
  .addCommand(info)
```

Upstream `secret` generates 32 random bytes as hex:

```ts
// reference/upstream-src/1.6.9/repository/packages/cli/src/commands/secret.ts:5
export const generateSecret = new Command("secret").action(() => {
  const secret = Crypto.randomBytes(32).toString("hex");
```

Upstream `info --json` redacts sensitive config:

```ts
// reference/upstream-src/1.6.9/repository/packages/cli/test/info.test.ts:71
it("should load and sanitize auth configuration", async () => {
```

## Ruby Schema & Migration Context

`info --json` exposes resolved configuration. For schema-related fields, prefer
**computed** values over raw config passthrough:

- `tables` (or equivalent) should reflect `BetterAuth::Schema.auth_tables`
  after merging core tables, all `plugins:` schema, and `additional_fields` —
  not merely echo the `plugins:` array from the file.
- When a plugin gem is in `plugins:` but fails to load, `info` should surface
  the load error; `doctor` / `migrate status` would otherwise plan against an
  incomplete schema.

`doctor` schema drift uses the same `SQLMigration.plan` as `migrate status`.
Tests for `info --json` should assert table keys match what `generate` would
emit for the same config (e.g. plugin table names in snake_case).

## Commands You Will Need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| CLI tests | `cd packages/better_auth-cli && bundle exec rake test` | exit 0 |
| Alias CLI tests | `cd packages/openauth-cli && bundle exec rake test` | exit 0 |
| Core doctor tests | `cd packages/better_auth && bundle exec ruby -Itest -Ilib test/better_auth/doctor_test.rb` | exit 0 if `Doctor` changes |
| Docs lint/build check | `cd docs-site && pnpm lint` | exit 0 if docs-site deps are installed; otherwise document why skipped |
| Ruby lint | `bundle exec standardrb packages/better_auth-cli/lib packages/better_auth-cli/test packages/openauth-cli/test packages/better_auth/lib/better_auth/doctor.rb packages/better_auth/test/better_auth/doctor_test.rb` | exit 0 |

## Scope

**In scope**:

- `packages/better_auth-cli/lib/better_auth/cli.rb`
- Optional new files under `packages/better_auth-cli/lib/better_auth/cli/`
  if extracting JSON diagnostics keeps `cli.rb` small.
- `packages/better_auth-cli/test/better_auth/cli_test.rb`
- `packages/openauth-cli/test/openauth/cli_test.rb`
- `packages/better_auth/lib/better_auth/doctor.rb` only for a small
  serialization helper if needed.
- `packages/better_auth-cli/README.md`
- `packages/openauth-cli/README.md`
- `docs-site/content/docs/concepts/cli.mdx`
- `docs-site/content/docs/installation.mdx`

**Out of scope**:

- Node framework/package-manager/database-client detection from upstream.
- Telemetry.
- Interactive prompts.
- Secret storage or writing `.env` files.
- New dependencies.

## Git Workflow

- Branch: `feat/cli-secret-info`
- Commit message style: `feat(cli): add secret and info diagnostics`
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Add `better-auth secret`

Implement a `secret` command in `BetterAuth::CLI`:

- Use Ruby stdlib `SecureRandom.hex(32)`.
- Print exactly one line by default: `BETTER_AUTH_SECRET=<64 lowercase hex chars>`.
- Return status 0.
- Do not write files.
- Add `secret --raw` if desired: prints only the 64-char secret. If you add
  `--raw`, test it. If you skip it, keep the command minimal.

Add tests:

- `run_cli("secret")` returns status 0 and stdout matches
  `/\ABETTER_AUTH_SECRET=[0-9a-f]{64}\n\z/`.
- Two calls produce different values.
- `better-auth secret` executable smoke test succeeds.

**Verify**: `cd packages/better_auth-cli && bundle exec rake test` -> exit 0.

### Step 2: Add `openauth secret` alias coverage

In `packages/openauth-cli/test/openauth/cli_test.rb`, add an executable test
for `openauth secret`.

**Verify**: `cd packages/openauth-cli && bundle exec rake test` -> exit 0.

### Step 3: Add `info --json`

Implement an `info` command with `--json` first. Non-JSON text output can be
minimal, but JSON is the machine-checkable support surface.

JSON shape should be stable and Ruby-specific:

```json
{
  "ruby": {"version": "...", "engine": "..."},
  "better_auth": {"version": "..."},
  "cli": {"version": "..."},
  "config": {
    "loaded": true,
    "path": "...",
    "base_url": "...",
    "base_path": "...",
    "adapter": "...",
    "dialect": "...",
    "tables": ["users", "..."],
    "endpoints_count": 0,
    "doctor": {"ok": [], "warnings": [], "errors": []}
  }
}
```

Requirements:

- Reuse the config resolver from plan 004.
- Populate `tables` from `BetterAuth::Schema.auth_tables(config)` (physical
  `model_name` values, including plugin tables and `additional_fields` columns
  on core tables) — not from a raw `plugins:` list in the config file.
- If no config is found, JSON should still include Ruby/Better Auth/CLI version
  and `"config": {"loaded": false, "error": "..."}`.
- Redact sensitive values. Do not serialize the full config object. Prefer a
  curated summary over recursive sanitization.
- Include doctor findings by calling `BetterAuth::Doctor.check` on the loaded
  config.
- Return status 0 when info can render even if config is missing. Return status
  1 only for invalid options or unreadable explicit config.

Add tests for:

- `info --json` without config returns valid JSON and `loaded: false`.
- `info --json --config <path>` returns valid JSON with redacted/curated config
  summary and doctor arrays.
- A config containing social provider secrets or arbitrary keys named
  `client_secret`, `password`, `token`, `api_key`, and `secret` does not leak
  those literal values into JSON.
- `info` non-JSON output includes enough human-readable lines to be useful:
  Ruby version, Better Auth version, config path or missing config, and doctor
  summary counts.

**Verify**: `cd packages/better_auth-cli && bundle exec rake test` -> exit 0.

### Step 4: Consider `doctor --json` as a small follow-up in the same PR

If implementing `info --json` naturally exposes a JSON serializer for doctor
results, add `doctor --json`:

- JSON output: `{"ok": [...], "warnings": [...], "errors": [...], "success": true/false}`.
- Exit status remains identical to text doctor: 0 if no errors, 1 if errors.
- Text output stays unchanged.

If this makes the PR too large, skip `doctor --json` and record it as follow-up
in `plans/README.md` maintenance notes.

**Verify**:
`cd packages/better_auth-cli && bundle exec rake test` and, if `Doctor`
changed, `cd packages/better_auth && bundle exec ruby -Itest -Ilib test/better_auth/doctor_test.rb`
-> exit 0.

### Step 5: Update usage and docs

Update usage in `CLI#usage` to include:

- `better-auth secret`
- `better-auth info [--config PATH] [--json]`
- `better-auth doctor --config PATH [--json]` only if Step 4 implemented it.

Update:

- `packages/better_auth-cli/README.md`
- `packages/openauth-cli/README.md`
- `docs-site/content/docs/concepts/cli.mdx`
- `docs-site/content/docs/installation.mdx`

Docs should show `better-auth secret` as the recommended CLI path and keep
`openssl rand -base64 32` as a no-gem fallback if desired.

**Verify**:
`cd docs-site && pnpm lint` -> exit 0 if deps are installed; otherwise record
why skipped.

### Step 6: Run lint

**Verify**:
`bundle exec standardrb packages/better_auth-cli/lib packages/better_auth-cli/test packages/openauth-cli/test packages/better_auth/lib/better_auth/doctor.rb packages/better_auth/test/better_auth/doctor_test.rb`
-> exit 0.

## Test Plan

- CLI tests parse JSON with `JSON.parse`.
- Tests assert sensitive placeholder values are absent from JSON strings.
- Executable tests cover `better-auth secret` and `openauth secret`.
- Keep JSON schema assertions strict enough for support tools to depend on.

## Done Criteria

- [ ] `better-auth secret` prints a new 64-char hex secret in env assignment
  form and exits 0.
- [ ] `openauth secret` delegates and exits 0.
- [ ] `better-auth info --json` emits valid JSON with Ruby, gem, CLI, config,
  schema, and doctor summary data.
- [ ] Sensitive config values are not present in `info --json` output.
- [ ] Docs and usage include the new commands.
- [ ] All required Ruby tests and lint commands exit 0.
- [ ] `plans/README.md` status row for plan 005 is updated.

## STOP Conditions

Stop and report if:

- The config object cannot be summarized without evaluating user code with side
  effects beyond the existing CLI config loading contract.
- Redaction would require serializing arbitrary config objects.
- Adding `info` requires new dependencies.
- `doctor --json` changes text doctor behavior or exit statuses.

## Maintenance Notes

Prefer a curated JSON diagnostic summary over broad object serialization. The
security review point for this PR is output leakage: tests must prove that
secrets, tokens, passwords, API keys, private keys, and database URLs do not
appear in JSON or text diagnostics.
