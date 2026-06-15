# Archived workflows

## `release.yml`

Automated GitHub Actions release workflow, disabled as of June 2026. Releases are
now manual; see `RELEASING.md`.

To restore CI publishing:

1. Move `release.yml` back to `.github/workflows/release.yml`.
2. Re-enable Trusted Publishing on RubyGems for each package.
3. Restore the workflow assertions in `test/release_version_manifest_test.rb`.
4. Add `.github/workflows/release.yml` back to the CI path filters in `ci.yml`.
