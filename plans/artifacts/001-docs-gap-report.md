# Plan 001 docs gap report

Generated from pinned upstream docs at `f484269228b7eb8df0e2325e7d264bb8d7796311` and local `docs-site/content/docs/**`.

## Unsupported or deprecated pages present locally

- `plugins/mcp.mdx` (SKIP_DEPRECATED, MCP) — Standalone mcp plugin is deprecated upstream; use oauth-provider migration material only. local=plugins/mcp.mdx lines 57/460
- `plugins/test-utils.mdx` (SKIP_UNPORTED, Test Utils) — Plugin is unported or intentionally excluded from Ruby supported docs. local=plugins/test-utils.mdx lines 114/374

## Supported plugin pages under 50% upstream length

- `plugins/2fa.mdx` — Two-Factor Authentication (2FA); status STUB; Supported Ruby plugin docs target. local=plugins/2fa.mdx lines 94/608
- `plugins/admin.mdx` — Admin; status STUB; Supported Ruby plugin docs target. local=plugins/admin.mdx lines 66/839
- `plugins/anonymous.mdx` — Anonymous  ; status STUB; Supported Ruby plugin docs target. local=plugins/anonymous.mdx lines 56/204
- `plugins/api-key/index.mdx` — API Key; status STUB; Supported Ruby plugin docs target. local=plugins/api-key.mdx lines 129/469
- `plugins/bearer.mdx` — Bearer Token Authentication; status STUB; Supported Ruby plugin docs target. local=plugins/bearer.mdx lines 48/149
- `plugins/device-authorization.mdx` — Device Authorization; status STUB; Supported Ruby plugin docs target. local=plugins/device-authorization.mdx lines 63/647
- `plugins/email-otp.mdx` — Email OTP; status STUB; Supported Ruby plugin docs target. local=plugins/email-otp.mdx lines 62/467
- `plugins/generic-oauth.mdx` — Generic OAuth; status STUB; Supported Ruby plugin docs target. local=plugins/generic-oauth.mdx lines 52/518
- `plugins/i18n.mdx` — i18n; status STUB; Supported Ruby plugin docs target. local=plugins/i18n.mdx lines 101/225
- `plugins/jwt.mdx` — JWT; status STUB; Supported Ruby plugin docs target. local=plugins/jwt.mdx lines 70/552
- `plugins/last-login-method.mdx` — Last Login Method; status STUB; Supported Ruby plugin docs target. local=plugins/last-login-method.mdx lines 51/407
- `plugins/magic-link.mdx` — Magic link; status STUB; Supported Ruby plugin docs target. local=plugins/magic-link.mdx lines 55/153
- `plugins/oauth-provider.mdx` — OAuth 2.1 Provider; status STUB; Supported Ruby plugin docs target. local=plugins/oauth-provider.mdx lines 191/2146
- `plugins/one-tap.mdx` — One Tap; status STUB; Supported Ruby plugin docs target. local=plugins/one-tap.mdx lines 53/210
- `plugins/one-time-token.mdx` — One-Time Token Plugin; status STUB; Supported Ruby plugin docs target. local=plugins/one-time-token.mdx lines 61/127
- `plugins/organization.mdx` — Organization; status STUB; Supported Ruby plugin docs target. local=plugins/organization.mdx lines 68/2516
- `plugins/passkey.mdx` — Passkey; status STUB; Supported Ruby plugin docs target. local=plugins/passkey.mdx lines 153/486
- `plugins/phone-number.mdx` — Phone Number; status STUB; Supported Ruby plugin docs target. local=plugins/phone-number.mdx lines 63/412
- `plugins/scim.mdx` — System for Cross-domain Identity Management (SCIM); status STUB; Supported Ruby plugin docs target. local=plugins/scim.mdx lines 112/624
- `plugins/siwe.mdx` — Sign In With Ethereum (SIWE); status STUB; Supported Ruby plugin docs target. local=plugins/siwe.mdx lines 64/295
- `plugins/sso.mdx` — Single Sign-On (SSO); status STUB; Supported Ruby plugin docs target. local=plugins/sso.mdx lines 68/1740

## Sidebar and plugin index checks

- `docs-site/components/sidebar-content.tsx`: no literal links for skip-plugin slugs (`agent-auth`, `autumn`, `chargebee`, `creem`, `dodopayments`, `mcp`, `oidc-provider`, `polar`, `test-utils`).
- `docs-site/lib/plugins.ts`: no literal metadata entries for skip-plugin slugs, but it derives official plugin cards from docs pages. Because `plugins/mcp.mdx` and `plugins/test-utils.mdx` exist locally, they can still be discovered as official plugin pages unless the discovery code or page placement changes.

## Notes

- `plugins/mcp.mdx` exists locally as a migration page but is classified `SKIP_DEPRECATED`; it should not be linked or presented as a supported standalone plugin.
- `plugins/test-utils.mdx` exists locally while upstream marks Test Utils as test-only; inventory classifies it `SKIP_UNPORTED` for supported docs parity.
- Ruby-specific integration pages (Rack, Rails, Roda, Hanami, Sinatra, Grape) are local-only and outside this upstream page inventory.
