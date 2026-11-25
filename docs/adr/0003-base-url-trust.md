# ADR 0003: Require a configured base URL or host allowlist

## Status

Accepted for the Better Auth v1.6.35 base URL port.

## Context

Better Auth can boot without a configured base URL. In that mode, it uses the request URL to select the origin for callbacks and links, including links that carry security tokens. RubyAuth previously required a static base URL and added `serving_origins` for deployments that needed more than one host.

## Decision

RubyAuth requires a static URL from configuration or the environment, or a dynamic `base_url` with a nonempty `allowed_hosts` list. Every token-bearing link uses a configured URL, a host matched by the allowlist, or a configured fallback.

Dynamic mode follows Better Auth's per-request resolution. The Ruby-only `serving_origins` option continues to support a fixed issuer and OAuth callback origin while serving links on other approved origins. It takes full HTTP(S) origin patterns and requires a static URL.

## Consequences

RubyAuth raises at startup when there is no URL or host allowlist. Deployments with a single host can set `BETTER_AUTH_URL`. Deployments that vary issuer or callback URLs by host can use dynamic `base_url`.
