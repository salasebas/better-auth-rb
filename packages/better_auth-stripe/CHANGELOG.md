# Changelog

## [Unreleased]

- Hardened subscription selection, organization scoping, and callback handling
  with targeted lifecycle regression coverage.
- Added a checked upstream test inventory for the Stripe plugin surface.

## [0.10.0] - 2026-05-21

- Improved Stripe metadata, utility behavior, adapter coverage, and rate-limit coverage.

## [0.7.0] - 2026-05-05

- Changed Stripe webhooks to reject requests when the configured Stripe client does not expose `webhooks.construct_event_async` or `webhooks.construct_event`, preventing unverified payload processing.
- Hardened Stripe subscription route middleware and webhook origin handling with regression coverage.

## [0.6.0] - 2026-05-02

- Modularized the Stripe plugin into upstream-aligned client, schema, middleware, hooks, route, metadata, type, and utility modules while keeping the existing public facade.
- Added high-value parity coverage for schema merging, plugin version metadata, reference authorization, subscription routes, webhook edge cases, and seat-based billing.
- Preserved custom schema field names and exposed plugin version metadata for closer upstream Better Auth parity.

## [0.2.1] - 2026-04-30

- Fixed Stripe checkout and subscription parity edge cases for reused customer IDs, plugin-owned schedule releases, missing checkout sessions, plan limits, and organization reference validation.
- Expanded Stripe organization and subscription parity coverage.

## [0.2.0] - 2026-04-29

- Aligned Stripe subscription, checkout, portal, webhook, customer, and organization flows with upstream Better Auth behavior.
- Expanded Stripe documentation and tests for subscription lifecycle and organization billing parity.

## [0.1.0] - 2026-04-28

- Initial external Stripe package extracted from `better_auth`.
