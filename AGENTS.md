# Repository Guide

Ruby port of Better Auth. Match upstream behavior unless a Ruby-specific
adaptation is documented.

Read the package-level `AGENTS.md` when one exists for the package you are
editing.

When a referenced document is not given by path, look for it from the workspace
root first, then the local package.

## Upstream

Reference target: Better Auth `v1.6.23` at commit
`9dfceee14021fc15a2fb93023f39635f25b0b5ba` (see
`reference/upstream-better-auth/VERSION.md`).

Fetch sources and tests when needed:

```bash
./scripts/fetch-upstream-better-auth.sh
```

Clone path: `reference/upstream-src/1.6.23/repository/`. Do not commit files
under `reference/upstream-src/<version>/`.

Before changing upstream-backed behavior: read the matching source and tests,
port idiomatically to Ruby, and document meaningful adaptations.

Keep shared auth behavior in `packages/better_auth`. Adapter and plugin
packages provide integration—do not duplicate core logic there.

## Development

- Use English for all repository content and collaboration.
- StandardRB, `# frozen_string_literal: true`, idiomatic Ruby naming.
- Core uses Minitest (`packages/better_auth`); adapters/plugins use RSpec.
- Prefer real, observable tests over mocks. Check upstream tests for parity work.
- Ask before adding new dependencies.

### Testing

Database and Redis services are shared across worktrees. Before running tests
that use them, start or verify the shared stack from the workspace root. The
fixed project name prevents worktrees from creating conflicting containers;
`--wait` returns only after services are running and healthy:

```bash
docker compose -p better-auth up -d --wait
```

Run database-backed suites through `scripts/with_test_databases.rb`. It gives
this worktree its own databases on the shared stack (`better_auth_<id>`, with
`<id>` a hash of the worktree path) and creates them if needed. Worktrees can
then run suites in parallel without resetting each other's tables:

```bash
cd packages/better_auth && ../../scripts/with_test_databases.rb bundle exec rake test:integration
scripts/with_test_databases.rb bundle exec rake test:integration   # workspace MySQL smoke
```

Tests read connection settings from `test/support/test_databases.rb`. Explicit
`BETTER_AUTH_*_URL` variables override it, as in CI, so the wrapper refuses to
run while they are set. Redis tests already isolate their keys with random
prefixes. Do not stop the shared stack while another worktree may be using it.

`scripts/with_test_databases.rb --prune` drops the databases of worktrees that
`git worktree list` no longer shows; add `--dry-run` to list them first. It
skips unsuffixed names and ids that are not 8 hex characters. It only knows
this clone's worktrees, so do not run it while another clone uses the stack.

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

## Agent skills

### Issue tracker

Public requests and external collaboration use GitHub Issues. Private planning
initiated by the maintainer uses the private `OpenAuth` Linear team and
`better-auth-rb` project. See `docs/agents/issue-tracker.md` for routing and
privacy rules.

### Triage labels

Triage uses the canonical `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix` labels. See `docs/agents/triage-labels.md`.

### Domain docs

This repository uses a single-context layout with `CONTEXT.md` and `docs/adr/` at the repository root. See `docs/agents/domain.md`.
