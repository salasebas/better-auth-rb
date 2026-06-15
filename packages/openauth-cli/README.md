# openauth-cli

Command-line alias for Better Auth Ruby.

```bash
openauth generate --config config/better_auth.rb --dialect postgres --output db/better_auth/schema.sql
openauth migrate --config config/better_auth.rb --yes
openauth migrate status --config config/better_auth.rb
openauth doctor --config config/better_auth.rb
openauth info --config config/better_auth.rb --json
openauth secret
openauth mongo indexes --config config/better_auth.rb
```

## Config discovery and `--cwd`

`openauth` delegates to `better_auth-cli` and supports the same `--cwd` and
config discovery behavior:

```bash
openauth doctor --cwd .
openauth generate --cwd . --dialect postgres --output db/better_auth/schema.sql
openauth info --cwd . --json
openauth secret
```

When `--config` is omitted, the CLI searches under `--cwd` for
`config/better_auth.rb`, `config/auth.rb`, `better_auth.rb`, or `auth.rb`.
Relative `--config` and `--output` paths resolve against `--cwd`.

This package depends on `better_auth-cli` and publishes the `openauth`
executable.
