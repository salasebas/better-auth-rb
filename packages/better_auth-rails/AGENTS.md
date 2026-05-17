# Rails Package Guide

Read this file when editing `packages/better_auth-rails/`.

This package is the Rails integration layer for `better_auth`. Keep
authentication behavior in `packages/better_auth`; this package should focus on
Rails mounting, engines, generators, helpers, configuration glue, docs, and
Rails-specific tests.

## Boundaries

- Do not duplicate core auth behavior here.
- Prefer delegating to `BetterAuth` core APIs instead of reimplementing flows.
- Keep Rails-only assumptions inside this package.
- `better_auth_rails.gemspec` is an alias gemspec; avoid changing it unless the
  alias package itself is part of the task.

## Testing

Use the package's existing RSpec setup for Rails integration and generator
coverage:

```bash
bundle exec rspec
```

When behavior depends on core auth semantics, add or update tests in
`packages/better_auth` as well.
