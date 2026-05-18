# Hanami Server Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden `packages/better_auth-hanami` server behavior against unsafe production defaults, request-helper gaps, upstream adapter drift, and blocking join patterns.

**Architecture:** Keep public Hanami integration small: configuration owns safety defaults, routing/helper code reuses a single auth instance, and Sequel adapter behavior is aligned with upstream Better Auth adapter semantics. Add regression specs before each behavior change.

**Tech Stack:** Ruby 3.2+, Hanami 2.3, Rack 3, Sequel, ROM SQL, RSpec.

---

## Checklist

- [x] Harden generated config in `packages/better_auth-hanami`: make `better_auth_url` required in generated provider/settings, fail fast when blank, and keep `trusted_origins` tied to the explicit URL.
- [x] Update Hanami README/package docs to state that production apps must configure a canonical auth URL and should not rely on Host header inference.
- [x] Change `SequelAdapter.from_hanami/from_container` so missing `db.gateway` raises in production unless `allow_memory_fallback` is explicitly enabled; keep warning-only fallback for test/development.
- [x] Make `BetterAuth::Hanami.auth` lazy initialization thread-safe so concurrent cold requests build only one auth instance.
- [x] Make generated routing reuse the configured/provider auth instance instead of forcing an override-created duplicate auth object for the same base path.
- [x] Rework `ActionHelpers` session resolution to pass full request headers through the auth API/hooks path, support plugin auth such as bearer headers, and attach any `Set-Cookie` cleanup headers to the Hanami response in `require_authentication`.
- [x] Fix Hanami `SequelAdapter` upstream parity:
  - preserve hidden join keys when `select` and `join` are combined;
  - support `mode: "insensitive"` for `eq`, `ne`, `in`, `not_in`, `contains`, `starts_with`, and `ends_with`;
  - apply defaults when required defaulted fields are explicitly `nil`;
  - convert bad user-shaped query input, invalid fields, and invalid pagination to controlled `BetterAuth::APIError` responses.
- [x] Reduce blocking join behavior by enforcing upstream default join limits and replacing unbounded child loading with a bounded per-parent strategy for collection joins.
- [x] Keep changes limited to `packages/better_auth-hanami` code/tests/docs plus this saved plan.

## Test Plan

- [x] Run `cd packages/better_auth-hanami && rbenv exec bundle exec rspec`.
- [x] Run `cd packages/better_auth-hanami && rbenv exec bundle exec standardrb`.
- [x] Add specs for generated provider URL validation, production memory fallback, thread-safe auth initialization, route/helper auth reuse, full helper headers and cleanup cookies, selected joins, insensitive filters, nil defaults, invalid adapter input, and bounded join query behavior.
