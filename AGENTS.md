# Repository Guide

Ruby port of Better Auth. Match upstream behavior unless a Ruby-specific
adaptation is documented.

Read the package-level `AGENTS.md` when one exists for the package you are
editing.

When a referenced document is not given by path, look for it from the workspace
root first, then the local package.

## Upstream

Target: Better Auth `v1.6.9` at commit
`f484269228b7eb8df0e2325e7d264bb8d7796311` (see
`reference/upstream-better-auth/VERSION.md`).

Fetch sources and tests when needed:

```bash
./scripts/fetch-upstream-better-auth.sh
```

Clone path: `reference/upstream-src/1.6.9/repository/`. Do not commit files
under `reference/upstream-src/<version>/`.

Before changing upstream-backed behavior: read the matching source and tests,
port idiomatically to Ruby, and document meaningful adaptations.

Keep shared auth behavior in `packages/better_auth`. Adapter and plugin
packages provide integration—do not duplicate core logic there.

## Development

- StandardRB, `# frozen_string_literal: true`, idiomatic Ruby naming.
- Core uses Minitest (`packages/better_auth`); adapters/plugins use RSpec.
- Prefer real, observable tests over mocks. Check upstream tests for parity work.
- Ask before adding new dependencies.

```bash
bundle exec rake ci          # workspace
bundle exec rake test        # core only
bundle exec standardrb       # lint
```

## Releasing

Before publishing gems or bumping versions, read and follow `RELEASING.md`.

## Public changes

Update the relevant package README and `docs-site/` when users need to know.

Do not commit unless the user asks for it or the task is explicitly about CI,
release, or repository automation.
