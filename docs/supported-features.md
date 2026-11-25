# Supported features

Every upstream Better Auth feature that RubyAuth ports, with the Ruby code and
the upstream code it matches. Use one entry as the scope of a parity check.
`docs/adr/0002-unsupported-upstream-features.md` lists what RubyAuth does not
port.

Paths: Ruby paths are relative to the package's `lib/better_auth/`. Upstream
paths are relative to `packages/` in the upstream repository.

To check one entry against an upstream version, use the prompts in
`docs/agents/parity-check.md`.

## Core (`better_auth`)

| Feature | Ruby | Upstream |
| --- | --- | --- |
| Router, endpoints and API errors | `router.rb`, `endpoint.rb`, `api.rb`, `api_error.rb`, `error.rb`, `response.rb`, `request_state.rb`, `path_matcher.rb`, `routes/ok.rb`, `routes/error.rb` | `better-auth/src/api/`, `core/src/api/`, `core/src/error/` |
| Origin check and trusted origins | `middleware/origin_check.rb`, `host.rb` | `better-auth/src/api/middlewares/` |
| Client IP | `request_ip.rb` | `core/src/utils/` |
| Rate limiting | `rate_limiter.rb` | `better-auth/src/api/rate-limiter/` |
| Configuration, context and plugin system | `configuration.rb`, `context.rb`, `auth.rb`, `plugin.rb`, `plugin_context.rb`, `plugin_loader.rb`, `plugin_registry.rb`, `secret_config.rb`, `url_helpers.rb`, `env.rb`, `logger.rb` | `better-auth/src/context/`, `better-auth/src/auth/`, `core/src/context/`, `core/src/env/` |
| Instrumentation | `instrumentation.rb` | `core/src/instrumentation/` |
| Cookies and sessions | `cookies.rb`, `session.rb`, `session_store.rb`, `routes/session.rb`, `routes/sign_out.rb` | `better-auth/src/cookies/`, `better-auth/src/api/routes/session.ts`, `better-auth/src/api/routes/sign-out.ts` |
| Crypto and password hashing | `crypto.rb`, `crypto/`, `password.rb` | `better-auth/src/crypto/`, `core/src/utils/` |
| Internal adapter and database hooks | `adapters/internal_adapter.rb`, `database_hooks.rb` | `better-auth/src/db/` |
| Database adapters | `adapters/base.rb`, `adapters/sql.rb`, `adapters/postgres.rb`, `adapters/mysql.rb`, `adapters/sqlite.rb`, `adapters/mssql.rb`, `adapters/memory.rb`, `adapters/join_support.rb` | `kysely-adapter/`, `memory-adapter/`, `core/src/db/adapter/` |
| Schema and migrations | `schema.rb`, `schema/`, `sql_migration.rb`, `migration_plan.rb` | `better-auth/src/db/`, `core/src/db/schema/` |
| Sign-up, sign-in and password | `routes/sign_up.rb`, `routes/sign_in.rb`, `routes/password.rb` | `better-auth/src/api/routes/sign-up.ts`, `better-auth/src/api/routes/sign-in.ts`, `better-auth/src/api/routes/password.ts` |
| Email verification | `routes/email_verification.rb` | `better-auth/src/api/routes/email-verification.ts` |
| Users and accounts | `routes/user.rb`, `routes/account.rb` | `better-auth/src/api/routes/update-user.ts`, `better-auth/src/api/routes/account.ts` |
| Social sign-in and OAuth state | `routes/social.rb`, `oauth_state.rb`, `oauth2.rb` | `better-auth/src/api/routes/sign-in.ts`, `better-auth/src/api/routes/callback.ts`, `better-auth/src/oauth2/`, `better-auth/src/state.ts`, `core/src/oauth2/` |
| Social providers | `social_providers.rb`, `social_providers/` | `core/src/social-providers/` |

## Core plugins (`better_auth`)

Each plugin is `plugins/<name>.rb` (plus `plugins/<name>/` when present) and
ports `better-auth/src/plugins/<upstream name>/`.

| Feature | Ruby name | Upstream name |
| --- | --- | --- |
| Access control | `access` | `access` |
| Additional fields | `additional_fields` | `additional-fields` |
| Admin | `admin` | `admin` |
| Anonymous | `anonymous` | `anonymous` |
| Bearer | `bearer` | `bearer` |
| Captcha | `captcha` | `captcha` |
| Custom session | `custom_session` | `custom-session` |
| Device authorization | `device_authorization` | `device-authorization` |
| Email OTP | `email_otp` | `email-otp` |
| Generic OAuth | `generic_oauth` | `generic-oauth` |
| Have I Been Pwned | `have_i_been_pwned` | `haveibeenpwned` |
| JWT | `jwt` | `jwt` |
| Last login method | `last_login_method` | `last-login-method` |
| Magic link | `magic_link` | `magic-link` |
| Multi-session | `multi_session` | `multi-session` |
| OAuth popup | `oauth_popup` | `oauth-popup` |
| OAuth proxy | `oauth_proxy` | `oauth-proxy` |
| One Tap | `one_tap` | `one-tap` |
| One-time token | `one_time_token` | `one-time-token` |
| OpenAPI | `open_api` | `open-api` |
| Organization | `organization` | `organization` |
| Phone number | `phone_number` | `phone-number` |
| Sign in with Ethereum | `siwe` | `siwe` |
| Two-factor | `two_factor` | `two-factor` |
| Username | `username` | `username` |

| Feature | Ruby | Upstream |
| --- | --- | --- |
| i18n | `plugins/i18n.rb` | `i18n/` |
| Expo (server plugin) | `plugins/expo.rb` | `expo/src/` (server part) |

## Packages

Each package is `packages/<gem>/lib/`. Core keeps a 13-line shim at
`plugins/<name>.rb` for `api_key`, `oauth_provider`, `passkey`, `scim`, `sso`,
and `stripe` that loads the gem.

| Feature | Gem | Upstream |
| --- | --- | --- |
| OAuth 2.1 and OIDC provider | `better_auth-oauth-provider` (and core `plugins/oauth_protocol.rb`) | `oauth-provider/` |
| SSO, SAML and OIDC sign-in | `better_auth-sso`, `better_auth-saml`, `better_auth-oidc` | `sso/` |
| SCIM | `better_auth-scim` | `scim/` |
| API keys | `better_auth-api-key` | `api-key/` |
| Redis secondary storage | `better_auth-redis-storage` | `redis-storage/` |
| Stripe | `better_auth-stripe` | `stripe/` |
| Passkey | `better_auth-passkey` | `passkey/` |
| Telemetry | `better_auth-telemetry` | `telemetry/` |
| CLI | `better_auth-cli` | `cli/` |
| MongoDB adapter | `better_auth-mongodb` (`better_auth-mongo-adapter` is the legacy name) | `mongo-adapter/` |
| Framework integrations | `better_auth-rails`, `better_auth-sinatra`, `better_auth-hanami`, `better_auth-grape`, `better_auth-roda` | none; compare request, response and cookie handling with `better-auth/src/integrations/` |

## Ruby-only

These have no upstream code in the monorepo. A parity check does not apply.

| Feature | Ruby |
| --- | --- |
| Dub | `plugins/dub.rb` (upstream ships it as the external `@dub/better-auth` package) |
| Configuration doctor | `doctor.rb` |

## Planned

[ADR 0002](adr/0002-unsupported-upstream-features.md#still-in-scope) lists
other features RubyAuth plans to port. Move each feature to its entry above
when the port lands.

The v1.6.35 parity check identified these additions since v1.6.23.

| Feature | Upstream behavior to port | Tracking |
| --- | --- | --- |
| Router | Match multiple unnamed wildcards in one path segment and expose each capture under its numeric key. | [#299](https://github.com/salasebas/better-auth-rb/issues/299) |
| Instrumentation | Let each auth instance disable tracing with `experimental.instrumentation.enabled`. Use the instance setting when tracing database hooks. | [#245](https://github.com/salasebas/better-auth-rb/issues/245) |
| Social sign-in and account linking | Pass the endpoint context to custom ID-token verifiers on sign-in and account linking. Forward it through the Apple, Cognito, Facebook, Google, LINE, Microsoft Entra ID, and PayPal providers. | [Sign-in #286](https://github.com/salasebas/better-auth-rb/issues/286), [linking #179](https://github.com/salasebas/better-auth-rb/issues/179), [providers #285](https://github.com/salasebas/better-auth-rb/issues/285) |
| Apple social provider | Include an S256 PKCE challenge in the authorization URL when the caller supplies a verifier. | [#280](https://github.com/salasebas/better-auth-rb/issues/280) |
| Captcha | Log structured warnings for Turnstile rejection, action mismatch, and hostname mismatch. Omit sensitive provider data. | [#273](https://github.com/salasebas/better-auth-rb/issues/273) |
| Last login method | Let `beforeStoreCookie` suppress the tracking cookie independently of database tracking. Log hook errors. | [#272](https://github.com/salasebas/better-auth-rb/issues/272) |
| OpenAPI | Include writable user fields from configuration and plugins in the sign-up and update-user request schemas. Preserve types and literal defaults, and mark required fields on sign-up. | [#276](https://github.com/salasebas/better-auth-rb/issues/276) |
| SAML sign-in | Support `idpInitiatedCallbackUrl` for each provider and as a global default, including for error redirects. | [#298](https://github.com/salasebas/better-auth-rb/issues/298) |
| CLI | Upgrade eligible dependencies to the running CLI version. Exit successfully without installing when all dependencies are current or newer. | [#256](https://github.com/salasebas/better-auth-rb/issues/256) |
