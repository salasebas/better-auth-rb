# Repository Guide

Ruby port of Better Auth. Match upstream behavior unless a Ruby-specific
adaptation is documented.

Read the package-level `AGENTS.md` when one exists for the package you are
editing.

## Upstream

Target: Better Auth `v1.6.9` at commit
`f484269228b7eb8df0e2325e7d264bb8d7796311` (see
`reference/upstream-better-auth/VERSION.md`).

The upstream monorepo is not committed. Fetch it when you need TypeScript
sources or tests:

```bash
./scripts/fetch-upstream-better-auth.sh
```

Clone path: `reference/upstream-src/1.6.9/repository/`

Do not commit files under `reference/upstream-src/<version>/`.

Before changing upstream-backed behavior: read the matching source and tests,
port idiomatically to Ruby (not line-by-line), and document meaningful Ruby
adaptations.

Keep shared auth behavior in `packages/better_auth`. Framework and plugin
packages provide integration—do not duplicate core logic there.

## Testing

- Avoid mocks unless the real dependency is impractical.
- Test observable behavior, not implementation details.
- Prefer database-backed tests when database behavior matters.
- Check upstream tests before porting or changing upstream-backed features.

## Versioning

Version each gem independently. Only bump versions for gems being released—not
for normal unreleased commits.

- Patch: backward-compatible fixes and internal/docs/CI updates.
- Minor: new public behavior while pre-`1.0` (includes breaking changes
  pre-`1.0`).
- Major: breaking public API after `1.0`.

Prerelease tags like `0.2.0.beta.1` are fine. Release tags must match package
versions exactly.

## Plans

Create saved plans only when the user asks, or when handing off to another
session. Save under `.docs/plans/` as `YYYY-MM-DD-HHMM--short-name.md` with
checkbox steps.

## Public changes

When changing public behavior, update the relevant package README and website
docs if users need to know.

## Hygiene

These files are read every agent session. Keep them high-signal: non-obvious
traps and repo-specific conventions, not architectural maps. Package-specific
rules belong in that package's `AGENTS.md`.
