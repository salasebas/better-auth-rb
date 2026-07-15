# ADR 0001: OAuth Popup Server Half

## Status

Accepted for a later implementation as an opt-in experimental plugin. This ADR
does not authorize or include runtime implementation.

## Context and demand

Better Auth v1.6.23 includes an experimental OAuth Popup plugin for signing in
from an embedded, cross-origin application. RubyAuth is server-first and does
not port the browser client, but applications may use the upstream JavaScript
client against the Ruby server. The server half therefore has a legitimate
interoperability purpose and is the only wholly absent server plugin route in
the current endpoint inventory.

There is no repository-local adoption data or customer request demonstrating
demand. Acceptance is based on the distinct embedded-application use case and
server-surface compatibility, not on measured usage.

## Decision

Implement the server half later as a separate, opt-in, explicitly experimental
plugin. Do not silently enable it, claim a stable contract, or port the
browser-only client. The future work requires its own executable plan, tests,
security review, and public documentation.

## Upstream server contract

The compatibility target is Better Auth v1.6.23:

- `GET /oauth-popup/start` requires `provider` and `popupOrigin`; it also accepts
  optional `popupNonce`, `callbackURL`, `errorCallbackURL`,
  `newUserCallbackURL`, comma-separated `scopes`, `requestSignUp`, and JSON
  `additionalData`.
- The opener origin is checked before any relay. An untrusted opener is rejected
  with `FORBIDDEN`. Once the opener is trusted, an untrusted redirect URL,
  unknown provider, or start-stage failure is returned as a completion page so
  the opener is not left waiting.
- The start route creates PKCE and OAuth state expiring after ten minutes,
  filters the upstream internal-state keys out of `additionalData`, and writes
  a ten-minute signed `oauth_popup` marker containing the opener origin and
  nonce.
- After-hooks cover both `/callback/*` and `/oauth2/callback/*`. Without a valid
  marker, normal callback redirects are unchanged. With a valid marker, the
  marker is expired and a recognized success or OAuth error redirect becomes a
  completion page.
- Success extracts the exact signed session-cookie value and relays it as the
  bearer token. The posted object is exactly
  `{ type, nonce, token, redirectTo, error }`, where `type` is
  `"better-auth:oauth-popup"`; optional success/error fields remain absent when
  not applicable.
- `postMessage` uses exactly the preserved opener origin as `targetOrigin`,
  never `"*"`, and the script closes the popup afterward. It chooses
  `window.opener`, falling back to `window.parent`, without posting to itself.
- JSON embedded in HTML escapes `<`, U+2028, and U+2029. The completion page has
  `Content-Type: text/html; charset=utf-8`,
  `Content-Security-Policy: default-src 'none'; script-src
  'sha256-tIo2K8VBC9SnhvdZ+9GsGkQoZm+jm/JcxL+d+i8b8KQ='; base-uri 'none'`,
  `Cache-Control: no-store`, and `Pragma: no-cache`.
- Callback `Set-Cookie` headers are preserved when the redirect is replaced,
  including session/cache cookies and the marker expiration.
- Embedded clients are expected to authenticate the relayed token with the
  bearer plugin. Matching upstream behavior, a missing bearer plugin warns once
  rather than failing plugin initialization.

## Security boundary

The preserved opener origin and nonce are authorization/correlation data, not
presentation fields. They must be integrity-protected in the signed marker and
must never be recovered from callback query parameters. The completion response
carries a live session token and must not be cached. Message delivery must use
the exact validated origin. Error descriptions and every other value embedded
in the HTML must pass the same JSON/script-context escaping.

Tampered, malformed, expired, or already-cleared markers must never produce a
token relay. A normal non-popup callback must remain a redirect. Hook ordering
must not drop or rewrite cookies set by core, bearer, session-cache, or another
callback hook.

## Ruby adaptation

RubyAuth will harden `popupOrigin` beyond the upstream matcher: it must be a
canonical absolute HTTP(S) origin with no credentials, non-root path, query, or
fragment. A trailing root slash may be normalized away before comparison. The
canonical origin must then pass `trusted_origin?` with relative paths disabled.

This is intentional because `postMessage` accepts an origin-only target. Custom
schemes, wildcard text, credentials, and URL components that do not belong to
an origin are not valid handoff targets even if a broader trusted-origin rule
could match them.

## Consequences

The future plugin adds a sensitive token-delivery path and therefore increases
the importance of origin validation, CSP stability, escaping, and response
header preservation. It enables embedded-app interoperability without adding a
Ruby browser client. Users must opt in to both the experimental popup plugin and
the bearer plugin for the intended cross-origin flow.

The server route remains pending until that implementation and its tests land.

## Implementation-plan requirements

The follow-up plan must include:

- a direct port of the start route, both callback matchers, signed marker, exact
  completion script, pinned CSP hash, and all cache/HTML headers;
- tests for missing, malformed, tampered, expired, consumed, and cleared marker
  behavior;
- built-in social and Generic OAuth callback coverage;
- exact origin, nonce, message payload, `targetOrigin`, and popup-close checks;
- preservation of every callback `Set-Cookie`, including session-cache cookies
  and marker expiration;
- malicious error-description tests covering `<`, U+2028, and U+2029;
- proof that non-popup and unrecognized callbacks remain redirects;
- proof that the relayed token authenticates through bearer, plus the one-time
  missing-bearer warning;
- validation of all three redirect URL fields and filtering of every internal
  state key from `additionalData`;
- hook-ordering tests with bearer and other redirect-rewriting plugins; and
- public experimental-status documentation and an explicit upstream adaptation
  note for canonical HTTP(S) opener origins.
