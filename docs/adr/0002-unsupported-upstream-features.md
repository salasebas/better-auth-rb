# ADR 0002: Upstream features RubyAuth does not port

## Status

Accepted on 2026-11-24. Only the maintainer changes this scope.

## Context

RubyAuth ports Better Auth server behavior to Ruby. Upstream also ships features
for AI agents, JavaScript runtimes, and many payment providers, and every new
release adds more. A port that follows upstream keeps pulling them in: parity
audits report them as missing, and version upgrades bring them along. The
2026-11-24 parity audit (#165) found several of them.

## Decision

RubyAuth does not port the features below. A parity audit records no difference
for them, and an upgrade to a newer upstream version skips them.

### AI agents and MCP

- MCP: the `mcp` plugin in v1.6.23 and the `@better-auth/mcp` package in v1.7.
- Agent Auth (`better-auth/agent-auth`, Agent Auth Protocol).
- CIMD, OAuth Client ID Metadata Documents (`@better-auth/cimd`, v1.7).
- CIBA, Client-Initiated Backchannel Authentication (`@better-auth/ciba`, v1.8).
- The CLI's AI, MCP, and infrastructure login and logout commands.
- The upstream docs' AI resources: the docs MCP server and agent skills.

### Better Auth Infrastructure

The hosted Better Auth service and its plugins: the dashboard (`dash`), audit
logs, Sentinel, and the email and SMS services.

### Anything outside the Ruby ecosystem

- Browser clients, client plugins, and JavaScript framework integrations, such
  as Next.js, Nuxt, Convex, and Effect.
- Electron (`@better-auth/electron`) and the client half of Expo
  (`@better-auth/expo`). The Expo server plugin stays.
- JavaScript ORM adapters (Drizzle, Prisma, Kysely), including Drizzle
  relations v2, and CLI schema generation for them.
- Deployment guides for JavaScript runtimes, such as Cloudflare Workers.
- Node.js-only behavior, such as detecting npm packages in telemetry.

### Payments other than Stripe

Polar, Autumn, Chargebee, Commet, Creem, Dodo Payments, and any payment plugin
that upstream adds later. Stripe stays (`better_auth-stripe`). The Polar social
sign-in provider is not a payment plugin and stays.

### Deprecated upstream APIs

Anything upstream marks `@deprecated` or has removed. Port the replacement
instead. Examples:

- v1.6: the `oidc-provider` plugin, which `better_auth-oauth-provider` replaces,
  and the `/forget-password/email-otp` endpoint, which
  `/email-otp/request-password-reset` replaces.
- v1.7: the legacy OAuth proxy callback path, which `/callback/:id/oauth-proxy`
  replaces; the option that `tokenEndpointAuth` replaces; and the context
  helpers that `getCurrentAuthEndpointContext` replaces.
- v1.8: the restriction options that `securityRestrictions` with `"mfa"` and
  `"sso"` replaces.

## Still in scope

These are missing or incomplete, but RubyAuth plans to port them:

- Test utilities (`@better-auth/test-utils` from v1.7), limited to the helpers
  that are useful in Ruby tests.
- OpenTelemetry instrumentation.
- From v1.7 and v1.8: the Cloudflare social sign-in provider, the OAuth
  provider's resource-server helpers (`oauthResource`), SCIM groups and roles,
  new i18n locales, and the identity-provider changes in the v1.8 upgrade guide.

## Consequences

- A parity finding about a feature on this list is out of scope. Close it as not
  planned and link this ADR.
- When an upgrade brings a new feature in one of these groups, add it to this
  list instead of porting it.
- Existing Ruby code for a feature on this list can be removed in its own PR.
