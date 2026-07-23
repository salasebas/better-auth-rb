# Domain Docs

How the engineering skills should consume this repository's domain documentation when exploring the codebase.

## Layout

This repository uses a single-context layout. The root `CONTEXT.md` defines the shared authentication domain and vocabulary. Repository-wide architectural decisions live under `docs/adr/`.

The packages under `packages/` are the core gem, framework and storage adapters, plugins, protocol implementations, command-line tooling, and aliases belonging to that shared context.

## Before exploring, read these

- **`CONTEXT.md`** at the repository root.
- **`docs/adr/`** — read ADRs that touch the area about to be changed.

If either is absent, proceed silently. Do not suggest creating it upfront. The domain-modeling skill creates and updates these documents when domain terms or architectural decisions are resolved.

## File structure

```text
/
├── CONTEXT.md
├── docs/
│   └── adr/
└── packages/
    ├── better_auth/
    ├── better_auth-rails/
    ├── better_auth-sso/
    └── ...
```

## Use the glossary's vocabulary

When output names a domain concept—in an issue title, refactor proposal, hypothesis, or test name—use the term defined in `CONTEXT.md`. Do not drift to synonyms the glossary explicitly avoids.

If a needed concept is not in the glossary, reconsider whether the language fits the project or note the gap for domain modeling.

## Flag ADR conflicts

If proposed work contradicts an existing ADR, surface the conflict explicitly rather than silently overriding the decision.
