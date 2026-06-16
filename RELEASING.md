# Releasing

Manual gem releases from `main`.

## Quick checklist

1. Confirm CI is green on `main`.
2. Update `.release.yml`, then run `rake release:sync_versions`.
3. Update package changelogs and root `CHANGELOG.md` when needed.
4. Run `make release-check` and `rake ci`.
5. Publish gems in dependency order with `gem build` and `gem push`.
6. Tag each published package, for example `better_auth-v0.10.0`.

## Version sync

All gems currently share one release version. Edit `.release.yml` once, then:

```bash
rake release:sync_versions
```

That updates package `VERSION` constants, OpenAuth alias `spec.version` values, and pinned alias dependencies.

## Publish order

1. `better_auth`
2. Dependent `better_auth-*` packages
3. `better_auth-mongo-adapter` after `better_auth-mongodb`
4. `rubyauth` and `openauth*` aliases after their matching `better_auth*` gems are on RubyGems

Example:

```bash
cd packages/better_auth
gem build better_auth.gemspec
gem push better_auth-0.10.0.gem
git tag -a better_auth-v0.10.0 -m "Release better_auth 0.10.0"
git push origin better_auth-v0.10.0
```

## Tags

Use package-prefixed tags that match the published version:

| Gem | Tag |
| --- | --- |
| `better_auth` | `better_auth-vX.Y.Z` |
| `better_auth-rails` | `better_auth-rails-vX.Y.Z` |
| `better_auth-passkey` | `better_auth-passkey-vX.Y.Z` |

The same pattern applies to the rest of the `better_auth-*`, `rubyauth`, and `openauth*` packages.

## Notes

- Do not bump versions for normal unreleased commits.
- Confirm dependency versions already exist on RubyGems before publishing dependents.
- The archived GitHub Actions workflow lives at `.github/workflows/archive/release.yml`.
