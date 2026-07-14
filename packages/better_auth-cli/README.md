# better_auth-cli

Command-line tools for Better Auth Ruby.

```bash
better-auth init --cwd . --framework rails
better-auth generate --cwd . --config config/better_auth.rb --dialect postgres --output db/better_auth/schema.sql
better-auth migrate --cwd . --config config/better_auth.rb --yes
better-auth migrate status --cwd . --config config/better_auth.rb
better-auth doctor --cwd . --config config/better_auth.rb
better-auth info --cwd . --config config/better_auth.rb --json
better-auth secret
better-auth mongo indexes --cwd . --config config/better_auth.rb
```

## Init

Scaffold Better Auth into an existing Ruby app (non-interactive, CI-safe):

```bash
# Explicit framework (recommended for CI)
better-auth init --cwd . --framework rails
better-auth init --cwd . --framework hanami|sinatra|roda|rack

# Opt-in detection (never implicit)
better-auth init --cwd . --detect-framework
```

- `--cwd` is **required** for every config-backed command, including `init`.
- Pass exactly one of `--framework` or `--detect-framework`.
- `rack` is never auto-detected; pass `--framework rack` for generic Rack apps.
- Framework packages own templates; the CLI orchestrates `rails generate`,
  `rake better_auth:install`, or writes a minimal Rack scaffold.

Use `--force` to overwrite CLI-owned Rack scaffold files only.

## Explicit flags (no silent defaults)

Every config-backed command requires `--cwd`. Config resolution requires either
`--config PATH` or `--discover-config` (opt-in replacement for implicit discovery).

```bash
# Explicit config path
better-auth doctor --cwd . --config config/better_auth.rb

# Search conventional paths under --cwd
better-auth doctor --cwd . --discover-config
```

`generate` also requires `--dialect` and `--output`. There is no implicit
`postgres` dialect fallback.

`info` requires `--cwd`; `--config` and `--discover-config` are optional (version-only output when omitted).

## Config discovery with `--discover-config`

When `--discover-config` is passed (without `--config`), the CLI searches under
`--cwd` in this order:

1. `config/better_auth.rb`
2. `config/auth.rb`
3. `better_auth.rb`
4. `auth.rb`

Relative `--config` and `--output` paths resolve against `--cwd`. Absolute paths
are used as-is.

The config file should return a `Hash` or `BetterAuth::Configuration`.
`doctor` validates the config, secret strength, HTTPS base URL, rate-limit
storage, SQL adapter support, and pending Better Auth migrations.
`mongo indexes` is for MongoDB adapters and idempotently ensures the indexes
declared by the active Better Auth schema.

Non-Rails Rack apps can use `init --framework rack`, then `generate`, `migrate
status`, `migrate --yes`, and `doctor` with the generated config.

## Secret and diagnostics

Generate a production-ready secret:

```bash
better-auth secret
```

The command prints `BETTER_AUTH_SECRET=<64 lowercase hex chars>`. Use
`better-auth secret --raw` to print only the secret value.

Inspect runtime and schema diagnostics as JSON:

```bash
better-auth info --cwd . --json
better-auth info --cwd . --config config/better_auth.rb --json
better-auth doctor --cwd . --config config/better_auth.rb --json
```

`info --json` returns Ruby, gem, CLI, resolved table names from
`BetterAuth::Schema.auth_tables`, endpoint counts, and doctor findings without
serializing sensitive config values.

## Command reference

| Command | Required flags | Optional flags |
| --- | --- | --- |
| `init` | `--cwd`, (`--framework` XOR `--detect-framework`) | `--force`, `--write-env-example`, `--plugin`, `--database-dialect` |
| `upgrade` | `--cwd` | `--yes` |
| `generate` | `--cwd`, (`--config` or `--discover-config`), `--dialect`, `--output` | — |
| `migrate` | `--cwd`, (`--config` or `--discover-config`), `--yes` | — |
| `migrate status` | `--cwd`, (`--config` or `--discover-config`) | — |
| `doctor` | `--cwd`, (`--config` or `--discover-config`) | `--json` |
| `info` | `--cwd` | `--config`, `--discover-config`, `--json` |
| `secret` | — | `--raw` |
| `mongo indexes` | `--cwd`, (`--config` or `--discover-config`) | — |
