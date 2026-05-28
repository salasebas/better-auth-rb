# Better Auth Ruby Docs

This documentation site was copied from upstream Better Auth and is being
adapted for the Ruby/Rack port.

Pages that still contain upstream TypeScript examples have a warning callout at
the top. Keep those pages in place so the upstream structure is not lost, but do
not treat them as final Ruby API docs until they are adapted.

## Run Locally

The docs app is a Next/Fumadocs app. Generated upstream folders such as `.next`
and `node_modules` are intentionally not copied into this repository.

```bash
pnpm install
pnpm run dev
```

This starts the docs site on [http://localhost:3000](http://localhost:3000).

## Adaptation Rules

- Prefer Ruby/Rack/Rails examples over TypeScript examples.
- Preserve upstream pages instead of deleting them.
- Add a top-of-page warning when a page is not adapted or not supported by the
  Ruby port yet.
- When replacing large upstream sections, keep a short MDX comment pointing to
  the matching file under `reference/upstream-src/1.6.9/repository/docs/`
  (run `./scripts/fetch-upstream-better-auth.sh` if missing).
