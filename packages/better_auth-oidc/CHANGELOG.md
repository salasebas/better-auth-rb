# Changelog

## Unreleased

- Split OIDC relying-party code out of `better_auth-sso` into a dedicated gem without `ruby-saml`.
- **Breaking:** Require public HTTPS OIDC endpoints unless their exact origin is explicitly trusted; validate and pin DNS destinations before built-in server-side requests and reject redirects.

## 0.10.0

- Initial release (extracted from `better_auth-sso` 0.10.0).
