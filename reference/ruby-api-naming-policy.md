# RubyAuth `auth.api` naming policy

RubyAuth exposes server endpoints as `auth.api.*` methods derived from endpoint
registry keys. This document defines how upstream Better Auth v1.6.9 registry
keys map to Ruby registry keys and how to add new endpoints without duplicate
aliases.

## Registry key → `auth.api` method

- Upstream plugin `endpoints` hashes use camelCase registry keys
  (`createOAuthClient`, `requestPasswordResetEmailOTP`).
- Ruby plugin `endpoints` hashes use snake_case registry keys
  (`create_oauth_client`, `request_password_reset_email_otp`).
- `BetterAuth::API` converts registry keys to method names with the same
  snake_case spelling (`auth.api.create_oauth_client`).

## Acronym segments

When converting upstream camelCase registry keys to Ruby, apply these segment
rules **before** generic camelCase splitting:

| Upstream segment | Ruby segment | Example upstream → Ruby |
| --- | --- | --- |
| `OAuth` | `oauth` | `createOAuthClient` → `create_oauth_client` |
| `OAuth2` | `oauth2` | `oAuth2Token` → `oauth2_token` |
| `OpenAPI` | `openapi` | `generateOpenAPISchema` → `generate_openapi_schema` |
| `OpenId` / `OIDC` | `openid` / `oidc` | `getOpenIdConfig` → `get_openid_config` |
| `SCIM` | `scim` | `listSCIMUsers` → `list_scim_users` |
| `SSO` | `sso` | `registerSSOProvider` → `register_sso_provider` |
| `OTP` | `otp` | `signInEmailOTP` → `sign_in_email_otp` |
| `JWT` | `jwt` | `getJwks` → `get_jwks` |
| `URL` | `url` | field names only |
| `API` | `api` | `createApiKey` → `create_api_key` |
| `SIWE` | `siwe` | `getSiweNonce` → `get_siwe_nonce` |

Implementation: `scripts/support/endpoint_naming.rb`.

## Forbidden patterns

Do not introduce split-acronym registry keys in new or renamed endpoints:

- `_o_auth_`, `_o_auth2_`, `_o_idc_`, `_open_id_`
- Duplicate registry keys for the same path and HTTP method

Use compact tokens instead: `oauth`, `oauth2`, `openid`, `oidc`.

## Approved shortenings

A small set of core routes use shorter Ruby registry keys that remain
semantically aligned with upstream:

| Upstream registry key | Ruby registry key |
| --- | --- |
| `listUserAccounts` | `list_accounts` |
| `linkSocialAccount` | `link_social` |
| `registerOAuthApplication` | `register_oauth_client` |
| `rotateClientSecret` | `rotate_oauth_client_secret` |
| `oAuthConsent` | `oauth2_consent` |
| `oAuthProxy` | `oauth_proxy` |
| `getOAuthServerConfig` | `get_oauth_server_config` |

Do not add new shortenings without updating this table and the parity tests.

## Alias policy

- One canonical registry key per path and HTTP method.
- Temporary compatibility aliases require an explicit deprecation note and a
  test asserting the alias resolves to the same endpoint object.
- Remove deprecated aliases in the next breaking release.

## Browser client mapping (document only)

- Upstream browser apps use `createAuthClient()` and `authClient.*` derived
  from HTTP paths.
- RubyAuth server code uses `auth.api.*` only.
- Future `@rubyauth/client` will follow upstream HTTP paths; this policy does
  not rename HTTP paths or JSON wire fields.

## Verification

```bash
ruby scripts/generate-upstream-endpoint-registry.rb
ruby scripts/generate-endpoint-inventory.rb
ruby scripts/compare-endpoint-api-names.rb
bundle exec rake test TEST=packages/better_auth/test/better_auth/endpoint_registry_parity_test.rb
```
