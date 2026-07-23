# Releasing Better Auth Ruby

Better Auth Ruby publishes 19 linked gems at one version.

Release Please is the sole owner of release version changes, package
changelogs, `<gem-name>/vX.Y.Z` tags, and GitHub Releases. The publisher only
builds and uploads the artifacts associated with those existing tags; it never
creates or moves a tag.

## One-time GitHub setup

Release Please uses the workflow's built-in `GITHUB_TOKEN`. No personal access
token or repository secret is required.

In **Settings > Actions > General > Workflow permissions**, select **Read and
write permissions** and enable **Allow GitHub Actions to create and approve
pull requests**. The `release-pr` job narrows its own permissions to
`contents: write` and `pull-requests: write`; all other jobs declare only what
they need.

In the `main` ruleset or branch protection, require both the `CI` and
`Integration` checks before merging. The release workflow also calls the
reusable CI and full-integration gates immediately before Release Please can
create tags, so a stale or bypassed pull-request check cannot become a release.

Pull request workflow runs created by `GITHUB_TOKEN` start in an
approval-required state. A repository user with write access must click
**Approve workflows to run** in the release pull request banner once; `CI` and
`Integration` then run normally for the pull request. Review and merge the
release pull request only after those checks succeed.

Create a protected GitHub environment named `release`. Apply the desired
reviewer and branch protections to it. The publish job receives its RubyGems
OIDC identity only after the environment allows the job to start.

Register one RubyGems Trusted Publisher for each of these 19 gems:

- [`better_auth`](packages/better_auth/)
- [`better_auth-api-key`](packages/better_auth-api-key/)
- [`better_auth-cli`](packages/better_auth-cli/)
- [`better_auth-grape`](packages/better_auth-grape/)
- [`better_auth-hanami`](packages/better_auth-hanami/)
- [`better_auth-mongo-adapter`](packages/better_auth-mongo-adapter/)
- [`better_auth-mongodb`](packages/better_auth-mongodb/)
- [`better_auth-oauth-provider`](packages/better_auth-oauth-provider/)
- [`better_auth-oidc`](packages/better_auth-oidc/)
- [`better_auth-passkey`](packages/better_auth-passkey/)
- [`better_auth-rails`](packages/better_auth-rails/)
- [`better_auth-redis-storage`](packages/better_auth-redis-storage/)
- [`better_auth-roda`](packages/better_auth-roda/)
- [`better_auth-saml`](packages/better_auth-saml/)
- [`better_auth-scim`](packages/better_auth-scim/)
- [`better_auth-sinatra`](packages/better_auth-sinatra/)
- [`better_auth-sso`](packages/better_auth-sso/)
- [`better_auth-stripe`](packages/better_auth-stripe/)
- [`better_auth-telemetry`](packages/better_auth-telemetry/)

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
3. Click **Approve workflows to run** once on the bot-created release pull
   request, review the synchronized versions and generated package changelogs,
   and merge only after `CI` and `Integration` pass.
4. The merge updates `.release-please-manifest.json` to versions whose component
   tags do not exist yet. On every push, the release workflow compares the
   current manifest and Release Please config with fetched tags. Any untagged
   component keeps both the reusable CI and full-integration gates active.
   Release Please cannot create tags or GitHub Releases unless both gates
   succeed.
5. Release Please creates the 19 component tags and GitHub Releases. Only when
   it reports `releases_created == 'true'` can the protected `publish` job run.
6. The publish job checks out the exact triggering commit with complete tag
   history and configures Ruby without installing the root bundle. Publication
   uses Ruby, RubyGems, and standard-library code only; installing development
   and test dependencies would add unrelated native database drivers and
   failure modes to the production path.
7. Before OIDC credentials are configured,
   `scripts/release/publish_gems.rb prepare tmp/release-gems` validates all
   three release manifests, every gemspec name and version, the internal
   dependency order, and every release tag. It then builds all 19 artifacts
   outside the package directories and records their SHA-256 checksums in an
   ephemeral inventory.
8. After the protected `release` environment grants approval, the workflow
   obtains short-lived OIDC credentials through RubyGems Trusted Publishing and
   runs
   `scripts/release/publish_gems.rb publish tmp/release-gems`.

The release pull request changes versions and changelogs but does not publish
anything while it is open. Normal pushes to `main` skip the release workflow's
reusable CI and full-integration gates only when every current manifest
component is already tagged, and continue creating or updating that pull
request. Merging the release pull request leaves the new manifest versions
untagged, which selects both gates before Release Please is allowed to create
the tags and GitHub Releases. The workflow accepts both configured
`<component>/vX.Y.Z` tags and legacy `<component>-vX.Y.Z` tags when determining
whether a manifest version was already released.

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
tag or overwrite a published version to recover. Use a new version only when
the intended gem contents must change.

There are two recovery paths:

1. **Transient failure in a valid historical workflow:** resolve the
   infrastructure, protected-environment, or Trusted Publisher problem and
   rerun the failed `publish` job from the same workflow run. This preserves
   the original `GITHUB_SHA` and is the preferred path.
2. **The historical workflow itself was broken:** after fixing
   `.github/workflows/release.yml` on `main`, manually run that same workflow
   with `workflow_dispatch` from the `main` branch and provide the immutable,
   already-tagged 40-character commit SHA as `release_commit`. Do not dispatch
   from a tag or another branch.

```bash
gh workflow run release.yml --ref main -f release_commit=RELEASE_COMMIT_SHA
```

The manual recovery job rejects a non-lowercase full SHA, checks out that exact
commit, verifies it is an ancestor of `origin/main`, and then asks the release
preparer to validate that all 19 component tags point to that SHA. The job uses
the protected `release` environment, whose approval happens before the job
starts. Within the approved job, the RubyGems credential action requests the
same `release.yml` Trusted Publishing OIDC identity used by normal releases
only after validation and preparation succeed. The preparer builds the
artifacts and records SHA-256 checksums; publishing re-hashes them and compares
any existing RubyGems artifacts before uploading what is missing.
Never move a release tag to make recovery pass.

If publication fails after the release pull request has merged, the committed
versions, changelogs, tags, and GitHub Releases remain valid. Do not edit or
revert them merely because RubyGems was temporarily unavailable. Fix the
credential, environment, or infrastructure problem and rerun the failed
`publish` job from the same workflow run. If some gems were already uploaded,
checksum verification skips them and continues with the missing gems.

If either pre-release gate fails, no release tags or GitHub Releases are created
and publishing cannot start. Fix the failure on `main`; because the manifest
versions remain untagged, that push and every later push rerun the full CI and
integration gates before Release Please. The gates stop recurring only after
every manifest component has its release tag. If Release Please itself fails
after both gates succeed, rerun the failed workflow. If the protected
environment is waiting for approval, approve the existing publish job rather
than starting a second release. A failed publish can be rerun safely from the
same workflow run because checksum verification skips artifacts that already
exist with identical contents.

## Local checks

This command builds exactly the 19 linked gems without publishing:

```bash
bundle exec rake release:check
```

Release preparation itself requires the Release Please tags to exist and point
to the current commit, so it is normally exercised by the release workflow.
