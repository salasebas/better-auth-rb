# Plan 025: Generate Database Schemas and Endpoint Resources

## Metadata

- **Status**: TODO
- **Priority**: P1
- **Owner**: Unassigned
- **Effort**: L
- **Risk**: MED
- **Category**: docs
- **Depends on**:
  - `plans/020-docs-parity-foundation.md`
  - `plans/022-docs-plugins-parity.md`
- **Planned at**: `2ce7a4a` (`chore(plans): remove legacy plans 001-018 and reset docs parity status`)
- **Planned date**: 2026-06-16

## Drift Check

Run this first:

```bash
git diff --stat 2ce7a4a..HEAD -- \
  docs-site/content/docs/reference/resources.mdx \
  docs-site/content/docs/reference/database-schemas.mdx \
  docs-site/scripts \
  docs-site/components/sidebar-content.tsx \
  docs-site/lib/database-schema.ts \
  packages/better_auth/lib/better_auth/schema.rb \
  packages/better_auth/lib/better_auth/schema/sql.rb \
  packages/better_auth/lib/better_auth/plugins/open_api.rb
```

If any of these files changed since planning, inspect the diff before executing.
Treat package files as read-only source of truth unless a separate plan explicitly
authorizes package changes.

## Why

`docs-site/content/docs/reference/resources.mdx` is currently a short resources
page. It does not provide the generated endpoint inventory or the complete
database schema reference that users need when integrating RubyAuth.

The requested behavior is explicit:

- document only features supported by this Ruby port;
- add all supported endpoints in one Resources page, grouped in a scannable way;
- add all generated database schemas, including table names, field names, and SQL
  creation output;
- use the library's generators/source-of-truth instead of manually mapping
  schemas and endpoints;
- do not document unsupported plugins such as `mcp` or upstream
  `oidc-provider`.

## Current State

- `docs-site/content/docs/reference/resources.mdx` is approximately 29 lines and
  only links to external resources.
- `docs-site/content/docs/reference/database-schemas.mdx` does not exist.
- `docs-site/lib/database-schema.ts` contains a manual core-table helper. It is
  not complete enough to be the source of truth for supported plugin schemas.
- `BetterAuth::Schema.auth_tables(options)` in
  `packages/better_auth/lib/better_auth/schema.rb` returns the logical table
  definitions after plugin schema merging and naming customization.
- `BetterAuth::Schema::SQL.create_statements(options, dialect:)` in
  `packages/better_auth/lib/better_auth/schema/sql.rb` generates SQL for
  `postgres`, `mysql`, `sqlite`, and `mssql`.
- `BetterAuth::Plugins.open_api` in
  `packages/better_auth/lib/better_auth/plugins/open_api.rb` generates OpenAPI
  paths from core endpoints plus enabled plugin endpoints and filters hidden,
  server-only, and disabled endpoints.

## Supported Plugin Set for Generation

Use the supported list finalized by Plan 022. At the time this plan was written,
that means generating schemas/endpoints for:

- Core/in-repo plugins: `username`, `anonymous`, `phone_number`, `two_factor`,
  `organization`, `jwt`, `device_authorization`, `siwe`,
  `last_login_method`, `magic_link`, `email_otp`, `one_time_token`,
  `multi_session`, `oauth_proxy`, `one_tap`, `generic_oauth`, `bearer`,
  `captcha`, `have_i_been_pwned`, and `dub`.
- External supported gems/pages: `api_key`, `passkey`, `oauth_provider`,
  `scim`, `sso`, and `stripe`.

Do not include:

- `mcp`
- upstream `oidc-provider` / Ruby `oidc_provider`
- `test-utils`
- non-Stripe payments plugins
- `i18n` unless Plan 019 has landed and the docs initiative explicitly marks it
  supported

If Plan 022 changes the supported plugin set, update this plan's generator input
to match Plan 022 before writing docs.

## Scope

In scope:

- Create `docs-site/scripts/generate-reference-resources.rb`.
- Create `docs-site/content/docs/reference/database-schemas.mdx`.
- Expand `docs-site/content/docs/reference/resources.mdx` with a generated
  endpoint reference in one page.
- Update `docs-site/components/sidebar-content.tsx` so `Database Schemas` is
  visible under Reference.
- Optionally adjust `docs-site/lib/database-schema.ts` only if existing docs
  would otherwise present the manual core-only helper as complete.

Out of scope:

- Changing package schema or OpenAPI behavior.
- Adding docs for unsupported plugins.
- Hand-mapping schemas or endpoint inventories.
- Splitting endpoints across many reference pages.

## Required Generation Approach

Create a checked-in generator script rather than pasting one-off output by hand.
The script should load the local Ruby package through Bundler and generate both
MDX files from RubyAuth APIs.

Suggested shape:

```ruby
# docs-site/scripts/generate-reference-resources.rb
# frozen_string_literal: true

require "bundler/setup"
require "better_auth"
require "better_auth/api_key"
require "better_auth/passkey"
require "better_auth/oauth_provider"
require "better_auth/scim"
require "better_auth/sso"
require "better_auth/stripe"
require "json"
```

Build a documentation auth instance with placeholder-only configuration:

- `secret: "x" * 40`
- `base_url: "http://localhost:3000/api/auth"`
- `email_and_password: {enabled: true}`
- `rate_limit: {storage: "database"}`
- all supported plugins from Plan 022
- `BetterAuth::Plugins.open_api` included for generation only

Use no-op callbacks and placeholder values where plugins require options, for
example `send_otp: ->(*) {}`, `send_magic_link: ->(*) {}`, and fake CAPTCHA or
Stripe credentials. The generator must not perform network calls.

Schema output must come from:

```ruby
tables = BetterAuth::Schema.auth_tables(auth.context.options)
BetterAuth::Schema::SQL.create_statements(auth.context.options, dialect: dialect)
```

Endpoint output must come from:

```ruby
schema = auth.api.generate_open_api_schema
paths = schema[:paths] || schema["paths"]
```

Manual code in the generator may format/group the generated data, but it must
not manually define the full table or endpoint inventory.

## Implementation Steps

1. **Confirm prerequisites**
   - Verify Plan 020 and Plan 022 are completed or that their supported-plugin
     manifest/list is final enough for this work.
   - Confirm `docs-site/content/docs/plugins/mcp.mdx` and unsupported plugin
     listing entries have been removed by Plan 022. If not, stop and finish Plan
     022 first.
   - Confirm project Ruby/Bundler works:

     ```bash
     ruby -v
     bundle exec ruby -v
     ```

     If this uses system Ruby or fails because Bundler is missing, fix the local
     Ruby setup before continuing. Do not hand-map schemas/endpoints as a
     workaround.

2. **Create the generator**
   - Add `docs-site/scripts/generate-reference-resources.rb`.
   - Support `--write` to write generated MDX files.
   - Support `--check` to regenerate content and fail when committed docs are
     stale.
   - Generate deterministic output: stable sort tables, fields, tags, methods,
     and paths.
   - Fail fast if generated paths/tables include `mcp`, `oidc_provider`,
     `oidc-provider`, or `test-utils`.

3. **Generate `reference/database-schemas.mdx`**
   - Add frontmatter:

     ```mdx
     ---
     title: Database Schemas
     description: Generated RubyAuth database tables and SQL for supported plugins.
     ---
     ```

   - Include `<RubyAuthDisclaimer />`.
   - State that the page is generated from `BetterAuth::Schema.auth_tables` and
     `BetterAuth::Schema::SQL.create_statements`.
   - Include a short configuration note: the generated reference enables the
     supported plugin set, database-backed rate limiting, and email/password
     auth; actual app schemas may differ if users disable plugins or customize
     names/fields.
   - For every generated table, document:
     - logical model key;
     - physical table/model name;
     - fields with logical name, physical field name, type, required, unique,
       index, reference, default, returned, and input flags where present.
   - Add SQL creation sections for `postgres`, `mysql`, `sqlite`, and `mssql`.

4. **Generate `reference/resources.mdx` endpoint section**
   - Keep useful existing resource links, but add a generated `Endpoint
     Reference` section.
   - Put all supported endpoints in this one page.
   - Group endpoints by OpenAPI tag, with stable fallback groups for untagged
     core endpoints.
   - Each endpoint row should include:
     - method;
     - path, including the `/api/auth` base path context;
     - operation id or endpoint id;
     - short summary/description;
     - authentication/security marker if OpenAPI exposes one;
     - request-body summary;
     - response summary.
   - Link prominently to `/docs/reference/database-schemas`.

5. **Update navigation**
   - Add the new `Database Schemas` page under the existing Reference section in
     `docs-site/components/sidebar-content.tsx`.
   - Keep `Resources` as the single endpoint index page.

6. **Handle the old manual schema helper**
   - Search for `docs-site/lib/database-schema.ts` usage.
   - If it is unused, remove it in the same change.
   - If it is still used by MDX components, either leave it alone or narrow its
     description so it is not presented as complete. The generated
     `database-schemas.mdx` page is the complete reference.

## Verification

Run:

```bash
bundle exec ruby docs-site/scripts/generate-reference-resources.rb --write
bundle exec ruby docs-site/scripts/generate-reference-resources.rb --check
rg 'mcp|oidc_provider|oidc-provider|test-utils' \
  docs-site/content/docs/reference/resources.mdx \
  docs-site/content/docs/reference/database-schemas.mdx
cd docs-site && pnpm lint && pnpm build
```

Expected:

- `--check` exits cleanly after `--write`.
- The `rg` command prints no matches.
- `pnpm lint` and `pnpm build` pass.

If useful, add a lightweight docs test that compares the count of generated
endpoint rows with the OpenAPI path/method count produced by the generator.

## Done Criteria

- `reference/resources.mdx` contains a generated, one-page endpoint index for
  all supported endpoints.
- `reference/database-schemas.mdx` contains all generated supported tables,
  field names, and SQL creation statements.
- The generator is checked in and can be rerun.
- Generated docs contain no `mcp`, `oidc-provider`, `oidc_provider`, or
  `test-utils` support claims.
- Supported external plugin endpoints/schemas are included where the Ruby gems
  expose them.
- Docs build and typecheck pass.

## STOP Conditions

Stop and update this plan before proceeding if:

- Plan 022 has not finalized the supported plugin set.
- Ruby/Bundler cannot run the local package.
- The generator requires enabling `mcp` or `oidc_provider` to succeed.
- Schema or OpenAPI generation fails for a supported plugin.
- Endpoint/table counts in generated MDX diverge from the source APIs after
  generation.

## Maintenance Notes

- Rerun `docs-site/scripts/generate-reference-resources.rb --write` whenever
  supported plugins, schemas, or OpenAPI generation changes.
- If Plan 019's i18n plugin is completed and documented as supported, add it to
  the generator config and regenerate both reference pages.
- Keep this page generated-first. Do not manually patch generated endpoint or
  table rows except through the generator.
