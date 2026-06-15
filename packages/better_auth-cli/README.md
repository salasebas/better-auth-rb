# better_auth-cli

Command-line tools for Better Auth Ruby.

```bash
better-auth generate --config config/better_auth.rb --dialect postgres --output db/better_auth/schema.sql
better-auth migrate --config config/better_auth.rb --yes
better-auth migrate status --config config/better_auth.rb
better-auth doctor --config config/better_auth.rb
better-auth info --config config/better_auth.rb --json
better-auth secret
better-auth mongo indexes --config config/better_auth.rb
```

## Config discovery and `--cwd`

Run commands from a project root without passing `--config` when a conventional
Ruby config file exists:

```bash
better-auth generate --cwd . --dialect postgres --output db/better_auth/schema.sql
better-auth migrate status --cwd .
better-auth migrate --cwd . --yes
better-auth doctor --cwd .
better-auth mongo indexes --cwd .
```

When `--config` is omitted, the CLI searches under `--cwd` (default: the current
directory) in this order:

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

Non-Rails Rack apps can use `generate`, `migrate status`, `migrate --yes`, and
`doctor` with a Ruby config file that declares the full auth configuration,
including plugins and additional fields.

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
better-auth doctor --cwd . --json
```

`info --json` returns Ruby, gem, CLI, resolved table names from
`BetterAuth::Schema.auth_tables`, endpoint counts, and doctor findings without
serializing sensitive config values.

Install `openauth-cli` for the `openauth` executable alias.
