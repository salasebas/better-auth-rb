# Plan 006: Establish the server-side upstream parity inventory and shared Minitest harness

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report; do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 7920aee..HEAD -- AGENTS.md reference/upstream-better-auth/VERSION.md packages/better_auth/Rakefile packages/better_auth/test/test_helper.rb packages/better_auth/test/better_auth/plugins/upstream_plugin_inventory_test.rb packages/better_auth/test`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding. On a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `7920aee`, 2026-06-15

## Why this matters

The repo is a Ruby server port of upstream Better Auth, but upstream test files
mix server behavior, browser/client behavior, framework integrations, and
TypeScript type assertions. Before adding hundreds of Ruby tests, the project
needs a machine-checked inventory that says which upstream tests count for
server parity and which are intentionally out of scope. This plan also creates
shared Minitest helpers for new parity tests so later plans do not copy another
round of `build_auth`, `rack_env`, and `cookie_header` helpers into every file.

## Current state

- `AGENTS.md` is the governing repo instruction. It says to match Better Auth
  `v1.6.9`, read upstream source/tests before upstream-backed behavior changes,
  keep shared auth behavior in `packages/better_auth`, use Minitest for core,
  and prefer real observable tests over mocks.
- `reference/upstream-better-auth/VERSION.md` pins upstream `better-auth`
  version `1.6.9` at commit `f484269228b7eb8df0e2325e7d264bb8d7796311`.
- `packages/better_auth/Rakefile` runs every `test/**/*_test.rb` with Minitest.
- `packages/better_auth/test/test_helper.rb` only requires `better_auth`,
  Minitest, and MySQL helpers. It does not expose shared auth/Rack/cookie
  helpers for parity tests.
- `packages/better_auth/test/better_auth/plugins/upstream_plugin_inventory_test.rb`
  currently checks only that each top-level Ruby plugin has some test owner; it
  does not classify upstream server/client/TS-only tests or track per-upstream
  suite parity.

Important excerpts:

```text
AGENTS.md:11-25
Target: Better Auth `v1.6.9` at commit
`f484269228b7eb8df0e2325e7d264bb8d7796311`.
Before changing upstream-backed behavior: read the matching source and tests,
port idiomatically to Ruby, and document meaningful adaptations.

AGENTS.md:32-35
- StandardRB, `# frozen_string_literal: true`, idiomatic Ruby naming.
- Core uses Minitest (`packages/better_auth`); adapters/plugins use RSpec.
- Prefer real, observable tests over mocks. Check upstream tests for parity work.
- Ask before adding new dependencies.

packages/better_auth/Rakefile:6-10
Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

packages/better_auth/test/test_helper.rb:3-8
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "better_auth"
require "minitest/autorun"
require "minitest/mock"
require "minitest/spec"
```

Current upstream/Ruby test-count signal from read-only recon:

```text
Upstream examples:
context/create-context.test.ts        115 tests
cookies/cookies.test.ts                54 tests
api/routes/session-api.test.ts         56 tests
plugins/organization/*.test.ts        182 server tests plus 2 client tests
plugins/email-otp/email-otp.test.ts    73 tests

Ruby examples:
auth_context_upstream_parity_test.rb   26 tests
cookies_test.rb                        11 tests
routes/session_routes_test.rb          29 tests
plugins/organization_test.rb           19 tests
plugins/email_otp_test.rb              21 tests
```

Server-only scope classification for the inventory:

- Include upstream server behavior under:
  `api/**`, `auth/**`, `call.test.ts`, `context/**`, `cookies/**`,
  `crypto/**`, `db/**` when it maps to Ruby core behavior,
  `instrumentation.*.test.ts`, `oauth2/**`, `plugins/**` server tests,
  `social.test.ts`, and `utils/url.test.ts`.
- Exclude upstream tests with no Ruby server equivalent:
  `client/**`, `types/**`, `integrations/next-js.test.ts`,
  `plugins/organization/client.test.ts`, `plugins/mcp/client/**`,
  `plugins/test-utils/test-utils.test.ts`, and test blocks that only assert
  TypeScript types, client proxy shape, React/Solid/Svelte/Vue behavior, or
  generated client APIs.
- Deprioritize, but still classify, DB adapter suites where Ruby is already
  ahead: external adapter matrices and SQL dialect execution tests should stay
  in their existing adapter-focused files unless a later plan explicitly targets
  them.

## Commands you will need

| Purpose | Command | Expected on success |
| --- | --- | --- |
| Core single-file test | `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/upstream_server_parity_inventory_test.rb` | exit 0 |
| Core tests | `cd packages/better_auth && bundle exec rake test` | exit 0 |
| Core lint | `cd packages/better_auth && bundle exec standardrb` | exit 0, no offenses |
| Workspace lint | `bundle exec standardrb packages/better_auth/test/test_helper.rb packages/better_auth/test/support packages/better_auth/test/better_auth/upstream_server_parity_inventory_test.rb` | exit 0 |

## Scope

**In scope**:

- `packages/better_auth/test/test_helper.rb`
- `packages/better_auth/test/support/auth_test_helpers.rb` (create)
- `packages/better_auth/test/support/upstream_server_parity.rb` (create)
- `packages/better_auth/test/better_auth/upstream_server_parity_inventory_test.rb` (create)
- `packages/better_auth/test/better_auth/plugins/upstream_plugin_inventory_test.rb` only if needed to avoid duplicate inventory responsibilities
- `plans/README.md`

**Out of scope**:

- Any `packages/better_auth/lib/**` source behavior change.
- Any package outside `packages/better_auth`.
- Any test that requires browser/client runtime, TypeScript compilation, Next.js,
  React, Solid, Svelte, Vue, or generated client API assertions.
- Any files under `reference/upstream-src/**`; read them but do not modify or commit them.

## Git workflow

- Branch: `test/server-parity-inventory`
- Commit message style: `test(core): add server parity inventory`
- Do not push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create shared auth test helpers

Create `packages/better_auth/test/support/auth_test_helpers.rb` with
`# frozen_string_literal: true`. Define a module, for example
`BetterAuthTestHelpers`, with only helpers needed by new parity tests:

- `build_auth(options = {})`: merges defaults
  `{base_url: "http://localhost:3000", secret: SECRET, database: :memory,
  email_and_password: {enabled: true}}` with caller options. Preserve caller
  `email_and_password` keys by merging them, do not overwrite them wholesale.
- `json_rack_env(method, path, body: {}, query: "", cookie: nil, headers: {})`:
  returns a Rack env using `StringIO`, JSON payload, localhost server fields,
  `REMOTE_ADDR`, `CONTENT_TYPE`, `CONTENT_LENGTH`, and `HTTP_ORIGIN`.
- `cookie_header(set_cookie)`: converts multiline `Set-Cookie` headers into a
  single `Cookie` header by taking each `name=value` pair.
- `json_response_body(body)`: parses `body.join` as JSON.
- `sign_up_cookie(auth, email:, password: "password123", name: "Test User",
  extra: {})`: signs up through `auth.api.sign_up_email(as_response: true)` and
  returns `cookie_header(headers.fetch("set-cookie"))`.

Update `packages/better_auth/test/test_helper.rb` to require the support file:

```ruby
require_relative "support/auth_test_helpers"
```

Do not refactor existing tests to use the new helper in this plan. Existing
duplicated helpers are stable and changing all of them is unnecessary risk.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest -e 'require "test_helper"; include BetterAuthTestHelpers; puts json_rack_env("GET", "/api/auth/ok").fetch("REQUEST_METHOD")'` -> prints `GET` and exits 0.

### Step 2: Create a server-only upstream parity classifier

Create `packages/better_auth/test/support/upstream_server_parity.rb` with:

- `UPSTREAM_ROOT = File.expand_path("../../../../reference/upstream-src/1.6.9/repository/packages/better-auth/src", __dir__)`.
- `EXCLUDED_UPSTREAM_TESTS`: exact relative paths for client/TS/framework-only
  files listed in "Current state".
- `SERVER_UPSTREAM_TEST_OWNERS`: a hash keyed by upstream relative test path.
  Each value should include:
  - `:owner` Ruby test path or array of paths.
  - `:status`, one of `:partial`, `:covered`, or `:ruby_not_applicable`.
  - `:plan`, one of `006`..`012` for files handled by this plan set.
  - `:notes` with one concise reason for partial or not applicable.

Seed the inventory with every upstream `**/*test.ts` file. Use `:partial` for
the core and plugin gaps covered by plans 002-007. Use `:ruby_not_applicable`
only for server files whose entire purpose is TypeScript-only or a JS-only
adapter not present in Ruby. Keep the list explicit; do not use broad regexes
that hide new upstream files.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest -e 'require "support/upstream_server_parity"; puts BetterAuth::TestSupport::UpstreamServerParity::SERVER_UPSTREAM_TEST_OWNERS.length'` -> prints a positive integer and exits 0.

### Step 3: Add the inventory test

Create `packages/better_auth/test/better_auth/upstream_server_parity_inventory_test.rb`.
It should:

- Require `test_helper` and `support/upstream_server_parity`.
- Scan `UPSTREAM_ROOT` for `**/*test.ts`.
- Assert every upstream test file is either in `EXCLUDED_UPSTREAM_TESTS` or
  `SERVER_UPSTREAM_TEST_OWNERS`.
- Assert every owner path exists when `:status` is not `:ruby_not_applicable`.
- Assert excluded files include a note explaining the exclusion.
- Assert no server owner entry points to `reference/upstream-src/**`.
- Assert the known high-gap files are present and marked with the expected
  plan numbers:
  - `context/create-context.test.ts` -> `007`
  - `cookies/cookies.test.ts` -> `008`
  - `api/routes/session-api.test.ts` -> `008`
  - `plugins/organization/organization.test.ts` -> `010`
  - `plugins/email-otp/email-otp.test.ts` -> `011`
  - `plugins/magic-link/magic-link.test.ts` -> `011`

This test is allowed to pass while entries are `:partial`; later plans should
move their entries to `:covered` when they finish.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/upstream_server_parity_inventory_test.rb` -> exit 0.

### Step 4: Reconcile the older plugin inventory test

If `plugins/upstream_plugin_inventory_test.rb` overlaps with the new inventory,
leave it in place as a fast plugin ownership smoke test. Only change it if it
becomes redundant or fails because of the new support module name. Do not delete
it without a specific reason.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/upstream_plugin_inventory_test.rb test/better_auth/upstream_server_parity_inventory_test.rb` -> exit 0.

### Step 5: Run the package checks

Run targeted test and lint commands before the full core suite.

**Verify**:

- `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/upstream_server_parity_inventory_test.rb` -> exit 0.
- `cd packages/better_auth && bundle exec standardrb test/test_helper.rb test/support test/better_auth/upstream_server_parity_inventory_test.rb` -> exit 0.
- `cd packages/better_auth && bundle exec rake test` -> exit 0.

## Test plan

- New inventory tests live in
  `packages/better_auth/test/better_auth/upstream_server_parity_inventory_test.rb`.
- New helper tests can be inline in the inventory test if needed, but do not add
  a separate helper unit test unless the helper logic becomes nontrivial.
- Existing test pattern to follow:
  `packages/better_auth/test/better_auth/plugins/upstream_plugin_inventory_test.rb`
  for filesystem inventory assertions and
  `packages/better_auth/test/better_auth/plugins/support/rack_rate_limit_helpers.rb`
  for small support modules.

## Done criteria

- [ ] `packages/better_auth/test/support/auth_test_helpers.rb` exists and is
  required from `packages/better_auth/test/test_helper.rb`.
- [ ] `packages/better_auth/test/support/upstream_server_parity.rb` classifies
  every upstream `**/*test.ts` file as server-owned or excluded.
- [ ] Client/TS-only exclusions are explicit and include a reason.
- [ ] The inventory test passes by itself.
- [ ] `cd packages/better_auth && bundle exec rake test` exits 0.
- [ ] `cd packages/better_auth && bundle exec standardrb` exits 0.
- [ ] No files outside the in-scope list are modified, except `plans/README.md`
  status update.

## STOP conditions

Stop and report back if:

- The upstream source tree is missing. Run `./scripts/fetch-upstream-better-auth.sh`
  only after confirming with the operator, because it writes under `reference/`.
- The current upstream target is no longer Better Auth `1.6.9`.
- The new inventory cannot classify an upstream test without reading behavior
  that appears client/browser/TS-only and ambiguous.
- Adding the helper requires changing existing test behavior.
- A verification command fails twice after a reasonable fix attempt.

## Maintenance notes

Later parity plans should update `SERVER_UPSTREAM_TEST_OWNERS` from `:partial`
to `:covered` as their domains are completed. Reviewers should reject broad
"excluded by glob" shortcuts; explicit classification is the point. When the
repo bumps upstream from `1.6.9`, this inventory is the first file to refresh.
