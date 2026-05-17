# Sinatra Package Guide

Read this file when editing `packages/better_auth-sinatra/`.

This package is the Sinatra integration layer for `better_auth`. Keep
authentication behavior in `packages/better_auth`; this package should focus on
Sinatra mounting, helpers, configuration glue, SQL migration tasks, docs, and
Sinatra-specific tests.

## Boundaries

- Do not duplicate core auth behavior here.
- Prefer delegating to `BetterAuth` core APIs instead of reimplementing flows.
- Keep Sinatra-only assumptions inside this package.
- Shared adapter behavior belongs in core or a dedicated adapter package, not in
  Sinatra integration code.

## Testing

Use the package's existing RSpec setup for Sinatra integration coverage:

```bash
bundle exec rspec
```

When behavior depends on core auth semantics, add or update tests in
`packages/better_auth` as well.
