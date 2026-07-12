# Better Auth OIDC

Enterprise OpenID Connect relying-party helpers for Better Auth Ruby.

Use this package when you need OIDC discovery, JWKS validation, and plugin extensions without pulling in SAML/XML dependencies.

```ruby
require "better_auth"
require "better_auth/oidc"
```

For the full SSO plugin (provider CRUD, domain verification, composed routes), add `better_auth-sso`:

```ruby
gem "better_auth-sso"
gem "better_auth-saml" # only when using SAML identity providers
```

```ruby
require "better_auth/sso"

BetterAuth.auth(plugins: [BetterAuth::Plugins.sso])
```

SCIM provisioning is separate (`better_auth-scim`). SAML SP primitives live in `better_auth-saml`.

## Endpoint security

OIDC discovery and manually configured endpoints must use publicly routable
HTTPS URLs by default. Provider registration, updates, discovery overrides, and
stored legacy configurations are validated before use. Built-in server-side
requests reject mixed public/private DNS answers, pin the connection to a
validated address, and do not follow redirects.

Private or plain HTTP IdPs require an explicit exact-origin entry in the
top-level `trusted_origins` configuration. The application's implicit
`base_url` and wildcard trusted origins do not grant private-network access.
Custom discovery and JWKS fetch hooks remain responsible for their own DNS,
redirect, proxy, and connection behavior.
