# better_auth-mongodb package

- [x] Review repository instructions and upstream Mongo adapter naming.
- [x] Choose canonical Ruby package name.
- [x] Create `better_auth-mongodb` as the canonical MongoDB adapter package.
- [x] Convert `better_auth-mongo-adapter` into a deprecated compatibility package.
- [x] Update core shim, docs, root wiring, and alias package dependencies.
- [x] Run focused tests for Mongo package loading and adapter behavior.

## Notes

Upstream Better Auth keeps the JavaScript package as `@better-auth/mongo-adapter`.
For the Ruby gem family, `better_auth-mongodb` matches the existing
`openauth-mongodb` alias package and is easier to discover on RubyGems.

Ruby-specific adaptation: keep `better_auth-mongo-adapter` installable and keep
`require "better_auth/mongo_adapter"` working, but route new docs and dependency
edges through `better_auth-mongodb`.

Implementation note: `better_auth-mongodb` owns the adapter implementation and
canonical `require "better_auth/mongodb"` entrypoint. The old package now
depends on `better_auth-mongodb` and loads the same adapter through a deprecated
shim.
