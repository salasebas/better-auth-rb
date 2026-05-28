# Release Process

This Ruby port uses package-prefixed release tags: merging code does not publish packages. A release happens when a version commit is already on the right branch and a tag for one specific gem is pushed.

## Branches

- `canary` is the integration branch. Merge completed feature branches here first.
- `main` is the stable release branch.
- Maintenance branches use `vX.Y.x`, for example `v0.1.x`, when an older line needs fixes after `main` has moved on.

Do not create separate folders for supported Rails lines. Keep compatibility in gem constraints and CI coverage. If a future release line needs to keep Rails 6 support while `main` moves to newer Rails-only behavior, branch from the last compatible commit into a maintenance branch and tag releases from that branch.

## Stable Release

1. Merge the desired `canary` changes into `main`.
2. Bump the relevant gem version file or files:
   - `packages/better_auth/lib/better_auth/version.rb`
   - `packages/better_auth-rails/lib/better_auth/rails/version.rb`
   - `packages/better_auth-passkey/lib/better_auth/passkey/version.rb`
   - `packages/better_auth-api-key/lib/better_auth/api_key/version.rb`
   - `packages/better_auth-sinatra/lib/better_auth/sinatra/version.rb`
   - `packages/better_auth-hanami/lib/better_auth/hanami/version.rb`
   - `packages/better_auth-oauth-provider/lib/better_auth/oauth_provider/version.rb`
   - `packages/better_auth-redis-storage/lib/better_auth/redis_storage/version.rb`
   - `packages/better_auth-mongo-adapter/lib/better_auth/mongo_adapter/version.rb`
   - `packages/better_auth-scim/lib/better_auth/scim/version.rb`
   - `packages/better_auth-sso/lib/better_auth/sso/version.rb`
   - `packages/better_auth-saml/lib/better_auth/saml/version.rb`
   - `packages/better_auth-oidc/lib/better_auth/oidc/version.rb`
   - `packages/better_auth-stripe/lib/better_auth/stripe/version.rb`
3. Let CI pass on `main`.
4. Push a tag matching the package and version, for example:

   ```bash
   git tag better_auth-v0.1.2
   git push origin better_auth-v0.1.2
   ```

The release workflow publishes only the gem named by the tag prefix:

- `better_auth-v0.1.2` publishes `better_auth`.
- `better_auth-rails-v0.1.2` publishes `better_auth-rails` and the `better_auth_rails` compatibility alias.
- `better_auth-passkey-v0.1.2` publishes `better_auth-passkey`.
- `better_auth-api-key-v0.1.2` publishes `better_auth-api-key`.
- `better_auth-sinatra-v0.1.2` publishes `better_auth-sinatra`.
- `better_auth-hanami-v0.1.2` publishes `better_auth-hanami`.
- `better_auth-oauth-provider-v0.1.2` publishes `better_auth-oauth-provider`.
- `better_auth-redis-storage-v0.1.2` publishes `better_auth-redis-storage`.
- `better_auth-mongo-adapter-v0.1.2` publishes `better_auth-mongo-adapter`.
- `better_auth-scim-v0.1.2` publishes `better_auth-scim`.
- `better_auth-sso-v0.1.2` publishes `better_auth-sso`.
- `better_auth-saml-v0.1.2` publishes `better_auth-saml`.
- `better_auth-oidc-v0.1.2` publishes `better_auth-oidc`.
- `openauth-saml-v0.1.2` publishes `openauth-saml`.
- `openauth-oidc-v0.1.2` publishes `openauth-oidc`.
- `better_auth-stripe-v0.1.2` publishes `better_auth-stripe`.

The target gem's version file must equal the tag version. Other gems may share that version number without being published.

The workflow publishes with RubyGems Trusted Publishing. Configure each RubyGems package as a trusted publisher for this repository and `.github/workflows/release.yml` before pushing a release tag.

Stable tags must be contained in `main` or a `vX.Y.x` maintenance branch. The workflow rejects stable tags from `canary`.

## Prerelease

Use RubyGems-compatible prerelease versions in the gem version files, for example:

```ruby
VERSION = "0.2.0.beta.1"
```

Then push the matching tag:

```bash
git tag better_auth-rails-v0.2.0.beta.1
git push origin better_auth-rails-v0.2.0.beta.1
```

Prerelease tags may be created from `canary`, `main`, or a maintenance branch.

## Maintenance Release

For an older supported line:

```bash
git switch -c v0.1.x v0.1.3
# cherry-pick or commit the fix
# bump to 0.1.4
git tag better_auth-sinatra-v0.1.4
git push origin v0.1.x better_auth-sinatra-v0.1.4
```

RubyGems versioning separates the release lines. Users who need that line pin the gem with normal version constraints, for example `~> 0.1.0`.

## Dry Run

Use the manual `Release` workflow with `dry_run: true` to build and validate the gems without publishing. Publishing only happens from pushed package-prefixed tags.
