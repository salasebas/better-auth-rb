# Releasing Better Auth Ruby

Better Auth Ruby publishes 19 linked gems at one version.

Release Please is the sole owner of release version changes, package
changelogs, `<gem-name>/vX.Y.Z` tags, and GitHub Releases. The publisher only
builds and uploads the artifacts associated with those existing tags; it never
creates or moves a tag.

## One-time GitHub setup

Create a fine-grained personal access token scoped only to this repository with
these repository permissions:

- Contents: read and write
- Pull requests: read and write

Store it as the Actions secret `RELEASE_PLEASE_TOKEN`. Release Please must use
this token because pull requests created with the built-in `GITHUB_TOKEN` do
not trigger the repository's pull request CI workflows.

Create a protected GitHub environment named `release`. Apply the desired
reviewer and branch protections to it. The publish job receives its RubyGems
OIDC identity only after the environment allows the job to start.

Register one RubyGems Trusted Publisher for each of these 19 gems:

- `better_auth`
- `better_auth-api-key`
- `better_auth-cli`
- `better_auth-grape`
- `better_auth-hanami`
- `better_auth-mongo-adapter`
- `better_auth-mongodb`
- `better_auth-oauth-provider`
- `better_auth-oidc`
- `better_auth-passkey`
- `better_auth-rails`
- `better_auth-redis-storage`
- `better_auth-roda`
- `better_auth-saml`
- `better_auth-scim`
- `better_auth-sinatra`
- `better_auth-sso`
- `better_auth-stripe`
- `better_auth-telemetry`

Use the same Trusted Publisher identity for every registration:

- Repository owner: `salasebas`
- Repository name: `better-auth-rb`
- Workflow filename: `release.yml`
- Environment: `release`

No long-lived RubyGems API key is stored by the repository.

## Release lifecycle

1. Squash-merge pull requests with Conventional Commit titles into `main`, as
   described in `CONTRIBUTING.md`.
2. The serialized `release-pr` job uses `release-please-config.json` and
   `.release-please-manifest.json` to create or update one linked-version pull
   request for all 19 Better Auth gems.
3. Review the synchronized versions and generated package changelogs, wait for
   CI, and merge the release pull request.
4. Release Please creates the 19 component tags and GitHub Releases. Only when
   it reports `releases_created == 'true'` can the protected `publish` job run.
5. The publish job checks out the exact triggering commit with complete tag
   history and installs the root bundle once.
6. Before OIDC credentials are configured,
   `scripts/release/publish_gems.rb prepare tmp/release-gems` validates all
   three release manifests, every gemspec name and version, the internal
   dependency order, and every release tag. It then builds all 19 artifacts
   outside the package directories and records their SHA-256 checksums in an
   ephemeral inventory.
7. The workflow configures RubyGems Trusted Publishing once and runs
   `scripts/release/publish_gems.rb publish tmp/release-gems`.

The release pull request changes versions and changelogs but does not publish
anything while it is open. Merging it triggers the same `release.yml` workflow
again: the `release-pr` job recognizes the merged release, creates the tags and
GitHub Releases, and then unlocks the `publish` job.

## Idempotency and recovery

Before making a network request, the publish phase re-hashes every prepared
artifact. For each gem it downloads the corresponding immutable RubyGems
artifact:

- A matching checksum means that gem was already published, so it is skipped.
- A missing artifact is pushed and then downloaded again until its checksum is
  verified.
- A different checksum, HTTP error, TLS or network error, push failure, or
  verification timeout stops the run immediately.

This makes a workflow rerun safe after a partial upload: already verified gems
are skipped and publishing resumes in dependency order. Never move a release
tag or overwrite a published version to recover. Resolve infrastructure or
Trusted Publisher configuration failures and rerun the same workflow; use a
new version only when the intended gem contents must change.

If publication fails after the release pull request has merged, the committed
versions, changelogs, tags, and GitHub Releases remain valid. Do not edit or
revert them merely because RubyGems was temporarily unavailable. Fix the
credential, environment, or infrastructure problem and rerun the failed
`publish` job from the same workflow run. If some gems were already uploaded,
checksum verification skips them and continues with the missing gems.

## Local checks

This command builds exactly the 19 linked gems without publishing:

```bash
bundle exec rake release:check
```

Release preparation itself requires the Release Please tags to exist and point
to the current commit, so it is normally exercised by the release workflow.
