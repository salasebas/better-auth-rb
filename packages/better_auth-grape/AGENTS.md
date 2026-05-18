# Grape Package Guide

Read this file when editing `packages/better_auth-grape/`.

This package is the Grape integration layer for `better_auth`. Keep
authentication behavior in `packages/better_auth`; this package should focus on
Grape mounting, helpers, configuration glue, SQL migration tasks, docs, and
Grape-specific tests.

## Boundaries

- Do not duplicate core auth behavior here.
- Prefer delegating to `BetterAuth` core APIs instead of reimplementing flows.
- Keep Grape-only assumptions inside this package.
- Shared adapter behavior belongs in core or a dedicated adapter package, not in
  Grape integration code.

## Testing

Use the package's RSpec setup for Grape integration coverage:

```bash
bundle exec rspec
```

When behavior depends on core auth semantics, add or update tests in
`packages/better_auth` as well.
