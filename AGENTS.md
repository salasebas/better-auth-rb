# Repository Guide

Ruby port of Better Auth. Match upstream behavior unless a documented
Ruby-specific adaptation says otherwise. When you add or change an adaptation,
document what differs from upstream and why in the package README and the
matching `docs-site/` page, and record it in `docs/adr/` when it is an
architectural decision.

Read the package-level `AGENTS.md` when one exists for the package you are
editing.

## Upstream

`reference/upstream-better-auth/VERSION.md` pins the upstream release.
`./scripts/fetch-upstream-better-auth.sh` clones it to
`reference/upstream-src/<version>/repository/`.

Before changing upstream-backed behavior, read the matching upstream source and
tests, then port them idiomatically to Ruby.

Port the pinned release as it is, including the decisions that look wrong:
validation order, error codes and messages, response shapes, misspelled public
names, and known bugs. A faithful port keeps every later upgrade a plain diff
between upstream tags. Behavior from a newer release waits until the pin moves
to it. Reviews judge fidelity to the pinned source: when upstream looks wrong,
keep the port faithful and file the concern as an issue.

End the PR title and every commit subject that ports upstream behavior with the
upstream version it ports, for example
`fix(sso): align OIDC state and PKCE flow (v1.6.23)`. Squash merges turn the PR
title into the commit on `main`.

Port only Ruby server behavior. `docs/adr/0002-unsupported-upstream-features.md`
lists what RubyAuth never ports: AI agents and MCP, the hosted Better Auth
Infrastructure, anything outside the Ruby ecosystem (JavaScript clients,
JavaScript ORMs, Electron), payment providers other than Stripe, and deprecated
upstream APIs. Check it against every upstream version you port, not only the
pin. Parity audits skip those
features. When an upgrade brings a new one, add it to that ADR instead of
porting it.

Keep shared auth behavior in `packages/better_auth`; adapter and plugin
packages only integrate it.

## Development

- Use English for all repository content and collaboration.
- StandardRB, `# frozen_string_literal: true`, idiomatic Ruby naming.
- Prefer real, observable tests over mocks.
- Ask before adding new dependencies.
- Update the relevant package README and `docs-site/` when users need to know.
- Do not edit `CHANGELOG.md` files or gem versions: Release Please owns
  versions, changelogs, and tags. Releases follow `RELEASING.md`.

### Testing

Run database-backed suites through `scripts/with_test_databases.rb`. It starts
the Docker stack that every worktree shares and gives this worktree its own
databases on it:

```bash
cd packages/better_auth && ../../scripts/with_test_databases.rb bundle exec rake test:integration
```

Leave the shared stack running, since other worktrees may be using it.
`scripts/with_test_databases.rb --prune` drops the databases of deleted
worktrees.

## Agent skills

### Issue tracker

Public requests and external collaboration use GitHub Issues. Private planning
initiated by the maintainer uses the private `OpenAuth` Linear team and
`better-auth-rb` project. See `docs/agents/issue-tracker.md` for routing and
privacy rules.

### Triage labels

See `docs/agents/triage-labels.md`.

### Domain docs

This repository uses a single-context layout with `CONTEXT.md` and `docs/adr/` at the repository root. See `docs/agents/domain.md`.
