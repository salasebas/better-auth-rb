# better_auth-mongodb

MongoDB database adapter package for Better Auth Ruby.

## Installation

Add the gem and require the package before configuring auth:

```ruby
gem "better_auth-mongodb"
```

```ruby
require "mongo"
require "better_auth/mongodb"

mongo_client = Mongo::Client.new(ENV.fetch("BETTER_AUTH_MONGODB_URL"))

auth = BetterAuth.auth(
  secret: ENV.fetch("BETTER_AUTH_SECRET"),
  database: ->(options) {
    BetterAuth::Adapters::MongoDB.new(
      options,
      database: mongo_client.database,
      client: mongo_client,
      transaction: false
    )
  }
)
```

The lambda form lets Better Auth pass the final configuration into the adapter,
including plugins, custom schemas, and advanced database options.

## Notes

This package depends on the official `mongo` gem. Keeping MongoDB support outside `better_auth` avoids installing MongoDB client dependencies for applications that only use SQL, Rails, Hanami, or in-memory storage.

The adapter stores Better Auth models in singular MongoDB collections by default, maps logical `id` values to Mongo `_id`, converts ObjectId-compatible ids through the Mongo driver, and supports the shared Better Auth database adapter contract.

Transactions are deployment-dependent. MongoDB multi-document transactions may
be unavailable on standalone servers and usually require a replica set plus
compatible driver/session settings. The setup example uses `transaction: false`;
enable transactions only when the MongoDB deployment supports them.

When using a replica set, remove `transaction: false` or pass
`transaction: true`. When using standalone local MongoDB, keep
`transaction: false`.

## Indexes

MongoDB does not run SQL-style migrations. The adapter can create recommended
indexes from Better Auth schema metadata, but this is an explicit setup step:

```ruby
adapter = BetterAuth::Adapters::MongoDB.new(
  options,
  database: mongo_client.database,
  client: mongo_client,
  transaction: false
)

adapter.ensure_indexes!
```

`ensure_indexes!` creates indexes for schema fields marked `unique: true` or
`index: true`, including plugin schemas and custom model or field names. It
skips Mongo `_id` because MongoDB creates that index automatically. The method
returns a summary of requested indexes so deployment scripts can log what was
applied.

## Limits

By default, `find_many` calls without an explicit `limit:` are capped at 100 records. Configure the default with Better Auth's advanced database option:

```ruby
auth = BetterAuth.auth(
  secret: ENV.fetch("BETTER_AUTH_SECRET"),
  advanced: {
    database: {
      default_find_many_limit: 250
    }
  },
  database: ->(options) {
    BetterAuth::Adapters::MongoDB.new(
      options,
      database: mongo_client.database,
      client: mongo_client,
      transaction: false
    )
  }
)
```

The same default applies to one-to-many join lookups when the join config does not set `limit:`. Passing an explicit `limit:` to `find_many` or to the join config overrides the default.

One-to-one joins ignore one-to-many limits. They are returned as a single object or `nil`.

Ruby's adapters accept scalar values for `in` and `not_in` filters and coerce
them to a one-element list. This is an intentional Ruby adapter-family behavior;
upstream's TypeScript adapter factory is stricter before the Mongo adapter sees
the query.

## Compatibility

The older `better_auth-mongo-adapter` gem and `require "better_auth/mongo_adapter"`
entrypoint are deprecated compatibility shims. New applications should use
`better_auth-mongodb` and `require "better_auth/mongodb"`.
