# Docs Site Guide

## Upstream doc parity

- Source reference: Better Auth v1.6.23 docs at
  `reference/upstream-src/1.6.23/repository/docs/content/docs/`. This pin does
  not imply that every local page has completed v1.6.23 parity review.
- Workflow: `node docs-site/scripts/port-upstream-doc.mjs <slug>`, then replace
  code blocks using `docs-site/scripts/docs-parity-manifest.json` test paths.
- Never port client-only sections (`createAuthClient`, framework JS integrations).
- Never document unsupported plugins as supported: `mcp`, upstream
  `oidc-provider`, `test-utils`, non-Stripe payment plugins.
- Verify with `cd docs-site && pnpm lint && pnpm build`.
