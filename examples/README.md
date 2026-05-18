# Better Auth Ruby — Integration Examples

This directory contains sample integrations for **Better Auth Ruby** across different application stacks.

Each subfolder is a standalone example project wired to the local monorepo gems. They are ready to run — no need to publish or clone anything extra.

## Structure

| Folder | Description |
|--------|-------------|
| `vanilla/` | Framework-agnostic (plain Ruby / Rack) integration using the core `better_auth` gem. |
| `rails-app/` | Integration with **Ruby on Rails** using the `better_auth-rails` adapter. |
| `sinatra/` | Integration with **Sinatra** using the `better_auth-sinatra` adapter. |
| `hanami_app/` | Integration with **Hanami** using the `better_auth-hanami` adapter. |
| `grape/` | Integration with **Grape** using the `better_auth-grape` adapter. |

## How it works

Every example `Gemfile` uses Bundler's `path:` option to point directly at the packages inside this monorepo:

```ruby
gem "better_auth", path: "../../packages/better_auth"
gem "better_auth-rails", path: "../../packages/better_auth-rails"
```

This means:
- You edit code in `packages/` and the change is immediately reflected in the example app.
- No need to bump versions, build `.gem` files, or publish to RubyGems.
- You can uncomment additional Better Auth plugins in the `Gemfile` when you want to test them.

## Running an example

### Vanilla (Rack)

```bash
cd examples/vanilla
bundle install
bundle exec puma
# open http://localhost:9292
```

### Sinatra

```bash
cd examples/sinatra
bundle install
bundle exec ruby app.rb
# open http://localhost:4567
```

### Rails

```bash
cd examples/rails-app
bundle install
bin/rails server
# open http://localhost:3000
```

### Hanami

```bash
cd examples/hanami_app
bundle install
bundle exec hanami server
# open http://localhost:2300
```

### Grape

```bash
cd examples/grape
bundle install
bundle exec rackup
# open http://localhost:9292
```

## Adding a New Example

1. Create a folder under `examples/<framework>/`.
2. Include a minimal, runnable project that demonstrates authentication setup, session handling, and at least one protected route.
3. Keep dependencies pinned to the local monorepo packages using `path:`.

## Notes

- These apps are intentionally minimal. They are meant for local manual testing and quick validation of Better Auth behavior in a real runtime.
- If you add a new plugin to the monorepo and want to test it here, uncomment the corresponding line in the example's `Gemfile` and run `bundle install` again.
