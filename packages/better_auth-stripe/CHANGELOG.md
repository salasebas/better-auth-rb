# Changelog

## [0.11.0](https://github.com/salasebas/better-auth-rb/compare/better_auth-stripe-v0.10.0...better_auth-stripe/v0.11.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **release:** OpenAuth alias gems, the openauth executable, and the better_auth_rails alias gem and require path are removed.

### Features

* **schema:** align migration plugin schema parity ([c0261dc](https://github.com/salasebas/better-auth-rb/commit/c0261dc1e5fd649557cd8a57b92c0609620c3767))


### Bug Fixes

* **ci:** restore package .ruby-version files for setup-ruby ([c18d220](https://github.com/salasebas/better-auth-rb/commit/c18d220065f3cb7cd2504bef7aa407e2c0c027eb))
* load external plugin gems without stub recursion ([4926bae](https://github.com/salasebas/better-auth-rb/commit/4926bae7520c17438de25e99cb2155839c177493))
* **saml:** fail closed without response parser ([#35](https://github.com/salasebas/better-auth-rb/issues/35)) ([0f9a7a4](https://github.com/salasebas/better-auth-rb/commit/0f9a7a4fb841153951b5f00ce42f01eee41b3112))
* **stripe:** align subscription lifecycle with upstream ([6faa517](https://github.com/salasebas/better-auth-rb/commit/6faa517db9b4972f6d1ecaae6d093ac30376c696))


### Miscellaneous Chores

* **release:** retire aliases and refresh parity tooling ([e099464](https://github.com/salasebas/better-auth-rb/commit/e0994643694267508a3c4d9be020bb1fd0e2e5a3))

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
