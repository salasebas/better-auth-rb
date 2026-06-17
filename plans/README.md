# Implementation Plans

Index for active improvement plans. Each executor must read the assigned plan
fully before starting, honor its STOP conditions, and update the status row when
done.

Status values: TODO | IN PROGRESS | DONE | BLOCKED | REJECTED.

## Other Active Plans

| Plan | Title | Depends on | Status |
| --- | --- | --- | --- |
| 019 | Core i18n plugin (`BetterAuth::Plugins.i18n`) | - | DONE |
| 019 | OAuth provider unified parity | - | TODO |

## Docs Parity Initiative (020–024)

Upstream Better Auth v1.6.9 docs → RubyAuth copy-first port under
`docs-site/content/docs/`. **Not executed** — abandoned after landing redesign
recovery; plans kept for reference only.

| Plan | Title | Depends on | Status |
| --- | --- | --- | --- |
| 020 | Docs parity foundation (tooling + manifest) | - | TODO |
| 021 | Concepts & getting started | 020 | TODO |
| 022 | Plugins (all server-side) | 020, 021 (rec.) | TODO |
| 023 | Adapters & authentication | 020 | TODO |
| 024 | Reference, guides & errors | 020–023 | TODO |

Recommended order if resumed: **020 → 021 → 022 → 023 → 024**.

## Notes For Executors

- Do not modify `reference/upstream-src/**`.
- Do not mark docs parity plans DONE without explicit maintainer approval.
- Keep core tests in Minitest under `packages/better_auth/test`.
