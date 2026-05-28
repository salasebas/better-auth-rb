# Core Package Guide

Read this file when editing `packages/better_auth/`.

`better_auth` is the framework-agnostic core gem. It should depend only on Rack
and small runtime dependencies. Rails, Sinatra, Hanami, and other framework code
belongs in adapter packages.

## Upstream Reference

This package maps to:

```text
reference/upstream-src/1.6.9/repository/packages/better-auth/
```

Run `./scripts/fetch-upstream-better-auth.sh` if that tree is missing locally.

Before changing upstream-backed behavior:

1. Read the matching TypeScript source.
2. Check the upstream tests for edge cases.
3. Port the behavior to idiomatic Ruby using this gem's existing patterns.
4. Document any meaningful Ruby-specific adaptation in the relevant plan or PR
   notes.

## Boundaries

- Keep public APIs under the `BetterAuth` namespace.
- Use `require "better_auth"` as the main require path.
- Do not add Rails, Sinatra, or Hanami dependencies here.
- Keep optional dependencies optional. For example, `bcrypt` is only required
  by apps that configure `password_hasher: :bcrypt`.
- Ask before adding a new dependency for convenience, optimization, or feature
  support.

## Development

```bash
bundle exec rake test
bundle exec standardrb
bundle exec rake ci
```

Use Minitest for this package. Test files live under `test/**/*_test.rb` and
should exercise real behavior where practical.

## Style

- StandardRB formatting.
- `# frozen_string_literal: true` in Ruby files.
- `snake_case` files and methods.
- `CamelCase` classes and modules.

Do not commit unless the user asks for it or the task is explicitly about CI,
release, or repository automation.
