# Internal documentation

Release and parity notes for Better Auth Ruby development.

## Contents

- `release-process.md` — gem release workflow
- `release-checklist.md` — pre-release verification
- `features/upstream-parity-matrix.md` — package-level upstream vs Ruby coverage

## Upstream reference

Behavioral reference for ports is the Better Auth TypeScript monorepo at the pin
in `reference/upstream-better-auth/VERSION.md`. Fetch a local clone with:

```bash
./scripts/fetch-upstream-better-auth.sh
```

Sources live under `reference/upstream-src/<version>/repository/` (gitignored).
