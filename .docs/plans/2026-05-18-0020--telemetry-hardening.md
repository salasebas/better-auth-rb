# Telemetry Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden `better_auth-telemetry` against server-side blocking, unsafe payload serialization, privacy leaks, and missing upstream parity tests.

**Architecture:** Keep the public telemetry API unchanged. Add an internal bounded HTTP dispatcher, sanitize event payloads before delivery, and tighten detectors/project IDs around Ruby-specific privacy and server-process behavior.

**Tech Stack:** Ruby 3.2+, Minitest, Rack-compatible Better Auth Ruby packages, Ruby stdlib `Net::HTTP`.

---

## Tasks

- [x] Add tests for bounded HTTP dispatch and subsequent publish delivery.
- [x] Add tests for HTTP write timeout and sanitized non-2xx logging.
- [x] Add tests for JSON-safe/redacted config payloads.
- [x] Add tests for project-id isolation and Bundler root fallback.
- [x] Add tests for `TEST=true` gating and custom-track failure coverage.
- [x] Implement bounded async HTTP delivery.
- [x] Harden `HttpClient` timeouts and response handling.
- [x] Sanitize telemetry config payloads and unknown adapter identifiers.
- [x] Fix project-id caching/fallback behavior and `TEST` gating.
- [x] Update docs and run package tests.

## Verification

- [x] `rbenv exec bundle exec rake test` in `packages/better_auth-telemetry`
      passed with 366 runs, 15327 assertions, 0 failures, 0 errors, 0 skips.
