# Better Auth upstream reference target

Pinned source reference for Better Auth Ruby development. Updating this pin does
not by itself mean that every Ruby behavior has reached parity with this release.

| Field | Value |
| --- | --- |
| Package | `better-auth` |
| Version | `1.6.23` |
| npm dist-tag checked | `latest` |
| Checked on | `2026-07-11` |
| Source registry | https://registry.npmjs.org/better-auth |
| Repository | https://github.com/better-auth/better-auth |
| Repository tag | `v1.6.23` |
| Repository commit | `9dfceee14021fc15a2fb93023f39635f25b0b5ba` |

## Local source tree

Clone the monorepo for behavioral reference (not committed to git):

```bash
./scripts/fetch-upstream-better-auth.sh
```

Expected path:

```text
reference/upstream-src/1.6.23/repository/
```

Package sources live under `packages/` (for example `packages/better-auth/`,
`packages/core/`, `packages/sso/`).

## Other versions

To fetch the newest stable patch in the pinned `1.6` series without changing
this reproducible pin, run:

```bash
./scripts/fetch-upstream-better-auth.sh --latest-patch
```

Pass a series such as `--latest-patch 1.7` to check another line, or an exact
version to compare a specific release. Update this file explicitly when bumping
the workspace reference target.

Do not commit upstream clones. Only this attribution directory is versioned.
