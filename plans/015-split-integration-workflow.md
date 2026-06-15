# Plan 015: Split service-backed integration tests into integration.yml

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report; do not improvise. When done, update the status row for this plan in
> `plans/README.md` unless a reviewer told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 7920aee..HEAD -- .github/workflows/ci.yml Rakefile packages/better_auth-redis-storage/Rakefile packages/better_auth-api-key/Rakefile packages/better_auth-passkey/Rakefile packages/better_auth-scim/Rakefile packages/better_auth-sso/Rakefile packages/better_auth-oauth-provider/Rakefile packages/better_auth-rails/Rakefile packages/better_auth-hanami/Rakefile packages/better_auth-api-key/test/better_auth/api_key/adapter_matrix_test.rb packages/better_auth-passkey/test/better_auth/passkey/adapter_matrix_test.rb packages/better_auth-scim/test/better_auth/scim/scim_adapter_matrix_test.rb packages/better_auth-sso/test/better_auth/sso/adapter_matrix_test.rb packages/better_auth-oauth-provider/test/better_auth/oauth_provider/adapter_smoke_test.rb`
>
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: plan 013
- **Category**: dx
- **Planned at**: commit `7920aee`, 2026-06-15

## Why this matters

The repository already has service-backed integration tests, but they are mixed
with normal PR CI and sometimes run only when a developer happens to have a
database service available locally. That makes PR feedback slower in some jobs
while leaving other integration coverage nondeterministic. A dedicated
`.github/workflows/integration.yml` lets the default CI run fast, deterministic
unit and smoke tests while service-backed PostgreSQL/MySQL/MSSQL/Redis/MongoDB
coverage runs intentionally on a separate trigger.

## Current state

- There is no `.github/workflows/integration.yml`.

- Root CI has a workspace packaging test command that omits
  `test/mysql_plugin_schema_smoke_test`, even though the root `Rakefile`
  includes it:

```ruby
# Rakefile:74-80
workspace_test_requires = [
  "./test/openauth_alias_packages_test",
  "./test/release_version_manifest_test",
  "./test/mysql_plugin_schema_smoke_test"
].map { |path| %(require "#{path}") }.join("; ")
sh %(bundle exec ruby -Itest -e '#{workspace_test_requires}')
```

```yaml
# .github/workflows/ci.yml:137-138
- name: Run workspace packaging tests
  run: bundle exec ruby -Itest -e 'require "./test/openauth_alias_packages_test"; require "./test/release_version_manifest_test"'
```

- `packages/openauth-grape/spec/openauth/grape_spec.rb` exists and passes
  locally, but there is no CI job covering that package:

```ruby
# packages/openauth-grape/spec/openauth/grape_spec.rb:5-10
RSpec.describe "openauth-grape" do
  it "loads the canonical Better Auth Grape adapter" do
    require "openauth/grape"

    expect(defined?(BetterAuth::Grape)).to eq("constant")
  end
end
```

- Current PR CI starts services and runs integration coverage in the normal
  workflow:

```yaml
# .github/workflows/ci.yml:140-193
test-core:
  services:
    postgres:
      image: postgres:latest
    mysql:
      image: mysql:latest
  # ...
  - name: Run tests
    working-directory: packages/better_auth
    run: bundle exec rake test
```

```yaml
# .github/workflows/ci.yml:432-467
test-redis-storage:
  services:
    redis:
      image: redis:7-alpine
  # ...
  - name: Run tests
    env:
      REDIS_URL: redis://localhost:6379/0
    run: bundle exec rake test
  - name: Run Redis integration tests
    env:
      REDIS_INTEGRATION: "1"
      REDIS_URL: redis://localhost:6379/0
    run: bundle exec rake test:integration
```

```yaml
# .github/workflows/ci.yml:469-525
test-mongodb:
  services:
    mongodb:
      image: mongo:latest
  # ...
  run: bundle exec rake test

test-mongo-adapter:
  services:
    mongodb:
      image: mongo:latest
  # ...
  run: bundle exec rake test
```

- Some integration tests are explicitly named/gated, for example Redis:

```ruby
# packages/better_auth-redis-storage/test/better_auth/redis_storage_integration_test.rb:10-17
class RedisStorageIntegrationTest < Minitest::Test
  def setup
    skip "set REDIS_INTEGRATION=1 to run real Redis integration" unless ENV["REDIS_INTEGRATION"] == "1"

    redis_url = ENV["REDIS_URL"] || "redis://localhost:6379/15"
    require "redis"
    @client = Redis.new(url: redis_url)
    @client.ping
```

- Other service-backed adapter tests are not consistently gated. Examples:

```ruby
# packages/better_auth-api-key/test/better_auth/api_key/adapter_matrix_test.rb:39-54
def test_postgres_adapter_api_key_lifecycle
  require "pg"

  connection = PG.connect(ENV.fetch("BETTER_AUTH_POSTGRES_URL", "postgres://user:password@localhost:5432/better_auth"))
  # ...
rescue LoadError
  skip "pg gem is not installed"
rescue PG::ConnectionBad
  skip "PostgreSQL test service is not available"
```

```ruby
# packages/better_auth-passkey/test/better_auth/passkey/adapter_matrix_test.rb:70-87
def test_mssql_adapter_persists_complete_passkey_flow
  require "sequel"
  require "tiny_tds"

  ensure_mssql_database
  connection = Sequel.connect(ENV.fetch("BETTER_AUTH_MSSQL_URL", "tinytds://sa:Password123!@127.0.0.1:1433/better_auth?timeout=30"))
  # ...
rescue Sequel::DatabaseConnectionError
  skip "MSSQL test service is not available"
```

## Commands you will need

If your shell resolves to macOS system Ruby 2.6, prefix commands with
`PATH="$HOME/.rbenv/shims:$HOME/.rbenv/bin:$PATH"`.

| Purpose | Command | Expected on success |
| --- | --- | --- |
| Workflow syntax smoke | `ruby -e 'require "yaml"; YAML.load_file(".github/workflows/ci.yml"); YAML.load_file(".github/workflows/integration.yml")'` | exit 0 |
| Fast workspace test | `bundle exec ruby -Itest -e 'require "./test/openauth_alias_packages_test"; require "./test/release_version_manifest_test"'` | exit 0 |
| OpenAuth Grape smoke | `bundle exec rspec packages/openauth-grape/spec --format progress` | exit 0 |
| Redis unit package | `cd packages/better_auth-redis-storage && BUNDLE_GEMFILE=Gemfile bundle exec rake test` | exit 0; real Redis tests skip unless explicitly enabled |
| Redis integration package | `cd packages/better_auth-redis-storage && REDIS_INTEGRATION=1 REDIS_URL=redis://localhost:6379/0 BUNDLE_GEMFILE=Gemfile bundle exec rake test:integration` | exit 0 when Redis is reachable |

## Scope

**In scope**:

- `.github/workflows/ci.yml`
- `.github/workflows/integration.yml` (create)
- `Rakefile`
- Package Rakefiles needed to expose clear fast/integration tasks:
  - `packages/better_auth-redis-storage/Rakefile`
  - `packages/better_auth-api-key/Rakefile`
  - `packages/better_auth-passkey/Rakefile`
  - `packages/better_auth-scim/Rakefile`
  - `packages/better_auth-sso/Rakefile`
  - `packages/better_auth-oauth-provider/Rakefile`
  - `packages/better_auth-rails/Rakefile`
  - `packages/better_auth-hanami/Rakefile`
- Existing service-backed test files when needed to add explicit integration
  tags or environment gates:
  - `packages/better_auth-api-key/test/better_auth/api_key/adapter_matrix_test.rb`
  - `packages/better_auth-passkey/test/better_auth/passkey/adapter_matrix_test.rb`
  - `packages/better_auth-scim/test/better_auth/scim/scim_adapter_matrix_test.rb`
  - `packages/better_auth-sso/test/better_auth/sso/adapter_matrix_test.rb`
  - `packages/better_auth-oauth-provider/test/better_auth/oauth_provider/adapter_smoke_test.rb`
  - `packages/better_auth-api-key/test/better_auth/api_key/redis_secondary_storage_integration_test.rb`
  - `packages/better_auth-rails/spec/better_auth/rails/postgres_integration_spec.rb`
  - `packages/better_auth-rails/spec/better_auth/rails/mysql_integration_spec.rb`
  - `packages/better_auth-hanami/spec/better_auth/hanami/sequel_database_integration_spec.rb`

**Out of scope**:

- Fixing currently failing product behavior. Do plan 013 first.
- Changing assertions in integration tests.
- Removing service-backed coverage.
- New CI providers or dependencies.
- Publishing or changing release automation.

## Git workflow

- Do not commit, push, or open a PR unless the operator explicitly asks.
- Keep workflow changes mechanical and reviewable. Avoid reformatting unrelated
  jobs.

## Steps

### Step 1: Define explicit fast and integration task boundaries

For Minitest packages, add or adjust Rake tasks so each package has an obvious
fast test target and a service-backed integration target. Keep `rake test`
fast by default where practical, and create `rake test:integration` for real
services.

Use existing Redis behavior as the model:

- Unit path: `bundle exec rake test`
- Integration path: `REDIS_INTEGRATION=1 bundle exec rake test:integration`

For adapter matrix tests that currently skip only when a service is missing,
add an explicit environment gate such as `ADAPTER_INTEGRATION=1` or
`BETTER_AUTH_ADAPTER_INTEGRATION=1` at the start of service-backed cases. Keep
fake/in-memory adapter cases in the fast suite.

For RSpec packages, use tags instead of file-name tricks when possible:

- Mark Rails PostgreSQL/MySQL specs as `:integration`.
- Mark Hanami Sequel database specs as `:integration`.
- Fast command should exclude `:integration`.
- Integration command should include only `:integration`.

**Verify**:
Run each changed package's fast task and confirm service-backed cases are either
excluded or explicitly skipped without trying to connect to local services.

### Step 2: Create `.github/workflows/integration.yml`

Create a dedicated workflow for service-backed tests. Recommended triggers:

- `workflow_dispatch`
- `schedule` once per day
- optionally `pull_request` only when paths under integration-sensitive
  packages change, if maintainers still want automatic PR integration coverage.

Recommended jobs:

- Redis integration:
  `packages/better_auth-redis-storage` with Redis service and
  `REDIS_INTEGRATION=1`.
- API key Redis secondary storage integration:
  `packages/better_auth-api-key` with Redis service and `REDIS_INTEGRATION=1`.
- SQL adapter matrix:
  API key, passkey, SCIM, SSO, and OAuth provider adapter matrix tests with
  PostgreSQL/MySQL/MSSQL services and the new adapter integration env var.
- Rails and Hanami database integration:
  PostgreSQL/MySQL/MSSQL where each package currently has coverage.
- MongoDB adapter packages:
  `packages/better_auth-mongodb` and `packages/better_auth-mongo-adapter` with
  MongoDB service.
- Root MySQL plugin schema smoke:
  include `test/mysql_plugin_schema_smoke_test` in this workflow if it needs a
  real MySQL service.

Use the same Ruby version setup pattern as `.github/workflows/ci.yml` and keep
package `working-directory` values explicit.

**Verify**:
`ruby -e 'require "yaml"; YAML.load_file(".github/workflows/integration.yml")'`
-> exit 0.

### Step 3: Slim `.github/workflows/ci.yml` to fast deterministic coverage

Update normal CI so it does not start Redis/MongoDB/MSSQL services just to run
integration tests. Keep fast unit and smoke coverage in PR CI.

Specific cleanup:

- Add coverage for `packages/openauth-grape/spec/openauth/grape_spec.rb` to
  normal CI because it is a fast one-example load smoke test.
- Keep workspace packaging tests in normal CI. Do not silently omit
  `test/mysql_plugin_schema_smoke_test`; either move it to
  `integration.yml` with a real MySQL service or keep it in fast CI only if it
  is deterministic without a service.
- Remove or retarget the explicit `Run Redis integration tests` step from
  normal CI.
- Move MongoDB service-backed jobs to `integration.yml` unless their package
  has a clear fast/fake subset that can run without MongoDB in normal CI.
- Make the aggregate `ci` job depend only on fast CI jobs after service-backed
  jobs are moved.

**Verify**:
`ruby -e 'require "yaml"; YAML.load_file(".github/workflows/ci.yml")'`
-> exit 0.

### Step 4: Document local commands in the relevant package Rakefiles or README

If package Rakefiles gain new tasks, ensure task descriptions (`desc`) make the
split discoverable:

- `rake test` or `rake test:unit`: fast tests, no external services required.
- `rake test:integration`: service-backed tests; requires the matching service
  URL/env vars.

Avoid broad README edits unless a package has no way to discover the new task
from `rake -T`.

**Verify**:
`cd <changed-package> && BUNDLE_GEMFILE=Gemfile bundle exec rake -T`
-> lists the new task descriptions.

## Test plan

- Workflow YAML parsing must pass for both `.github/workflows/ci.yml` and
  `.github/workflows/integration.yml`.
- Fast package tasks must run without local Redis/MongoDB/PostgreSQL/MySQL/MSSQL
  services.
- Integration package tasks must run against local services when the relevant
  env vars are set.
- `packages/openauth-grape` must be covered by a fast CI job.

## Done criteria

- [ ] `.github/workflows/integration.yml` exists and parses as YAML.
- [ ] Normal `.github/workflows/ci.yml` parses as YAML and its aggregate job no
      longer depends on service-backed integration-only jobs.
- [ ] Redis integration runs only from integration workflow or explicit local
      integration task.
- [ ] Adapter matrix tests with PostgreSQL/MySQL/MSSQL have an explicit
      integration gate or integration task.
- [ ] Rails and Hanami database specs are excluded from fast RSpec commands and
      included in integration commands.
- [ ] `packages/openauth-grape/spec` is covered by fast CI.
- [ ] Root MySQL plugin schema smoke is covered intentionally in either fast CI
      or integration CI, with a comment or job name making that choice clear.
- [ ] `plans/README.md` status row for plan 015 is updated.

## STOP conditions

Stop and report if:

- Plan 013 has not landed and MSSQL integration tests still fail when MSSQL is
  reachable.
- The live workflow or Rakefile structure no longer matches the excerpts above.
- A proposed fast task still attempts to connect to a real external service.
- Moving a service-backed job would remove coverage entirely rather than moving
  it to `integration.yml`.
- A verification command fails twice after a reasonable fix attempt.

## Maintenance notes

- After this plan lands, future service-backed tests should default to the
  integration workflow, not normal PR CI.
- Keep skipped-service behavior for local developer friendliness, but CI should
  set explicit env vars so integration coverage is intentional rather than
  accidental.
