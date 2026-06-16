# RubyAuth documentation site

Next.js + Fumadocs site for [RubyAuth](https://github.com/salasebas/better-auth-rb) — the Ruby port of Better Auth. Documentation content lives in `content/docs/` and is maintained in this monorepo (not synced from the upstream TypeScript repository).

## Quick start

```bash
pnpm install
pnpm dev
```

Open [http://localhost:3000](http://localhost:3000) to preview.

## Commands

| Command | Purpose |
| --- | --- |
| `pnpm dev` | Start the dev server (Turbopack) |
| `pnpm build` | Production build |
| `pnpm start` | Serve a production build |
| `pnpm lint` | Typecheck with `tsc --noEmit` |
| `pnpm format:check` | Lint MDX/Markdown with remark |

## Environment

Copy `.env.example` to `.env.local`:

| Variable | Purpose |
| --- | --- |
| `NEXT_PUBLIC_URL` | Public site URL (metadata, OG, llms.txt links) |
| `GITHUB_TOKEN` | Optional — higher GitHub API rate limits for community/changelog |
| `NEXT_PUBLIC_LLMS_TXT_URL` | Optional override for the LLM docs index URL |

## Structure

```
app/                 # Next.js App Router routes
components/          # UI, landing, docs, blog components
content/docs/        # RubyAuth MDX documentation
content/blogs/       # Blog posts (optional; empty is OK)
lib/                 # Source loaders, branding, metadata
public/branding/     # RubyAuth logo assets
```

## Branding

Use constants from `lib/branding.ts` (`BRAND_NAME`, `BRAND_DESCRIPTION`, etc.) instead of hardcoding product names.

## Related packages

Ruby gems and adapters live under `packages/` at the repo root. Do not change core auth behavior from docs-site tasks — update MDX and site code only.
