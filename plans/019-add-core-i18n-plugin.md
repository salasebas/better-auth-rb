# Plan 019: Add Full Server-Side i18n Plugin Support

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan in
> `plans/README.md` unless a reviewer tells you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 0d19370..HEAD -- packages/better_auth/lib/better_auth packages/better_auth/test/better_auth packages/better_auth/README.md README.md docs-site/content/docs/plugins docs-site/content/docs/concepts/plugins.mdx docs-site/lib/plugins.ts`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `0d19370`, 2026-06-16

## Why this matters

Upstream Better Auth `v1.6.9` includes `@better-auth/i18n`, a server plugin
that translates error messages by locale. RubyAuth currently documents i18n as
upstream-only and has no `BetterAuth::Plugins.i18n` factory, so Ruby users
cannot localize server errors without hand-writing hooks.

This plan adds the full server-applicable surface: translations, fallback
locale selection, header/cookie/session/callback locale detection, translated
`APIError` responses with `originalMessage`, direct `auth.api` support, Rack
HTTP support, lazy loading, inventory coverage, and Ruby-first docs. Do not add
a new gem package: upstream i18n is a small hook-only plugin with no schema,
routes, database tables, or runtime dependencies, so it belongs in
`packages/better_auth/lib/better_auth/plugins/i18n.rb`.

## Current state

Relevant upstream files for behavior parity:

- `reference/upstream-src/1.6.9/repository/packages/i18n/src/index.ts` -
  plugin implementation.
- `reference/upstream-src/1.6.9/repository/packages/i18n/src/i18n.test.ts` -
  upstream server tests.
- `reference/upstream-src/1.6.9/repository/docs/content/docs/plugins/i18n.mdx` -
  user-facing option docs.

Important upstream excerpts:

```ts
// reference/upstream-src/1.6.9/repository/packages/i18n/src/index.ts:27
function parseAcceptLanguage(header: string | null): string[] {
  if (!header) return [];
  return header
    .split(",")
    .map((part) => {
      const [localeStr, quality = "q=1"] = part.trim().split(";");
      const q = Number.parseFloat(quality.replace("q=", ""));
      const locale = localeStr?.trim().split("-")[0] ?? "";
      return { locale, q };
    })
    .filter((item) => item.locale.length > 0)
    .sort((a, b) => b.q - a.q)
    .map((item) => item.locale);
}
```

```ts
// reference/upstream-src/1.6.9/repository/packages/i18n/src/index.ts:69
const availableLocales = Object.keys(options.translations);
// lines 71-85: defaultLocale = explicit valid locale, else "en", else first
// locale, else throw "i18n plugin: translations object is empty..."
```

```ts
// reference/upstream-src/1.6.9/repository/packages/i18n/src/index.ts:98
for (const strategy of opts.detection) {
  // "header", "cookie", "session", "callback" are checked in order.
  // First strategy that yields an available locale wins.
}
return opts.defaultLocale;
```

```ts
// reference/upstream-src/1.6.9/repository/packages/i18n/src/index.ts:153
return {
  id: "i18n",
  hooks: {
    after: [{
      matcher: () => true,
      handler: createAuthMiddleware(async (ctx) => {
        const returned = ctx.context.returned;
        if (!isAPIError(returned)) return;
        const errorCode = (returned.body as Record<string, unknown>)?.code;
        if (typeof errorCode !== "string") return;
        const locale = await detectLocale(ctx);
        const translation = opts.translations[locale]?.[errorCode];
        if (!translation) return;
        throw new APIError(returned.status, {
          code: errorCode,
          message: translation,
          originalMessage: returned.message,
        });
      }),
    }],
  },
  options: opts,
}
```

Upstream tests to port:

- Header detection: `fr`, `de`, missing locale, q-values, base locale extraction
  from `fr-CA` (`i18n.test.ts:33-117`).
- Cookie detection with custom cookie name and priority over header
  (`i18n.test.ts:120-147`).
- Callback detection, including direct `auth.api` with no request object
  (`i18n.test.ts:182-238`).
- Non-error responses unchanged (`i18n.test.ts:241-266`).
- Default locale selection and empty translations validation
  (`i18n.test.ts:269-375`).

Current Ruby plugin infrastructure:

```ruby
# packages/better_auth/lib/better_auth/plugin_loader.rb:6
PLUGIN_FILES = {
  additional_fields: "plugins/additional_fields",
  custom_session: "plugins/custom_session",
  # ...
  expo: "plugins/expo"
}.freeze
```

```ruby
# packages/better_auth/lib/better_auth/plugin_loader.rb:58
PLUGIN_ID_TO_LOADER = {
  "additional-fields" => :additional_fields,
  # ...
  "expo" => :expo
}.freeze
```

```ruby
# packages/better_auth/lib/better_auth/plugin.rb:5
FIELDS = [
  :id, :init, :endpoints, :middlewares, :hooks, :schema, :migrations,
  :options, :version, :client, :rate_limit, :error_codes, :on_request,
  :on_response, :adapter
].freeze
```

```ruby
# packages/better_auth/lib/better_auth/api.rb:114
endpoint_context.returned = result.response
endpoint_context.response_headers = result.headers.dup
after_result = run_after_hooks(endpoint_context)
```

```ruby
# packages/better_auth/lib/better_auth/api_error.rb:23
def initialize(status, message: nil, headers: {}, code: nil, body: nil)
  @status = status.to_s.upcase
  @status_code = STATUS_CODES.fetch(@status, 500)
  @headers = normalize_headers(headers)
  @code = code || @status
  @body = body
  super(message || default_message)
end
```

```ruby
# packages/better_auth/lib/better_auth/api_error.rb:32
def to_h
  return body if body

  {
    code: code,
    message: message
  }
end
```

Important Ruby adaptation: many Ruby routes raise `APIError` with the HTTP
status as `code` and the upstream error-code message as `message`, for example
`packages/better_auth/lib/better_auth/routes/sign_in.rb:61`:

```ruby
raise APIError.new("UNAUTHORIZED", message: BASE_ERROR_CODES["INVALID_EMAIL_OR_PASSWORD"])
```

Because upstream i18n translates by error code, the Ruby i18n plugin must infer
`INVALID_EMAIL_OR_PASSWORD` from the error message and the merged error catalog
when `APIError#code` is only the HTTP status. Do this only inside the i18n
plugin. Do not globally change `APIError#to_h` or every route's error code in
this plan.

Existing hook-only plugin style:

```ruby
# packages/better_auth/lib/better_auth/plugins/last_login_method.rb:13
Plugin.new(
  id: "last-login-method",
  schema: last_login_method_schema(config),
  hooks: {
    after: [
      {
        matcher: ->(_ctx) { true },
        handler: ->(ctx) { apply_last_login_method(ctx, config) }
      }
    ]
  },
  options: config
)
```

Existing tests and inventory:

```ruby
# packages/better_auth/test/better_auth/plugins/upstream_plugin_inventory_test.rb:6
def test_every_top_level_plugin_file_has_an_explicit_test_owner
  top_level_plugins = Dir[File.join(plugin_root, "*.rb")].map { |path| File.basename(path, ".rb") }.sort
  direct_tests = Dir[File.join(test_root, "*_test.rb")].map { |path| File.basename(path, "_test.rb") }
  assert_empty coverage.select { |_plugin, category| category.nil? }
end
```

Current docs explicitly exclude i18n:

```md
<!-- docs-site/content/docs/plugins/index.mdx:50 -->
## Not documented in RubyAuth

Upstream-only plugins removed from this docs site include MCP, agent-auth, i18n,
test-utils, and third-party payment plugins...
```

Docs-site package instructions:

```md
<!-- docs-site/AGENTS.md -->
- Ruby examples in MDX; mark incomplete features with `<UnderDevelopment />`.
- Verification: `cd docs-site && pnpm lint`, `cd docs-site && pnpm build`.
```

## Commands you will need

| Purpose | Command | Expected on success |
| --- | --- | --- |
| New i18n tests | `cd packages/better_auth && bundle exec ruby -Itest -Ilib test/better_auth/plugins/i18n_test.rb` | exit 0 |
| Plugin loader tests | `cd packages/better_auth && bundle exec ruby -Itest -Ilib test/better_auth/plugin_loader_test.rb` | exit 0 |
| Plugin inventory | `cd packages/better_auth && bundle exec ruby -Itest -Ilib test/better_auth/plugins/upstream_plugin_inventory_test.rb` | exit 0 |
| Core tests | `cd packages/better_auth && bundle exec rake test` | exit 0 |
| Core lint | `cd packages/better_auth && bundle exec standardrb lib/better_auth/plugins/i18n.rb lib/better_auth/plugin_loader.rb test/better_auth/plugins/i18n_test.rb test/better_auth/plugin_loader_test.rb test/better_auth/plugins/upstream_plugin_inventory_test.rb` | exit 0 |
| Docs typecheck | `cd docs-site && pnpm lint` | exit 0 |
| Docs build | `cd docs-site && pnpm build` | exit 0 |
| Workspace CI | `bundle exec rake ci` | exit 0 |

## Scope

**In scope**:

- `packages/better_auth/lib/better_auth/plugins/i18n.rb` (new).
- `packages/better_auth/lib/better_auth/plugin_loader.rb`.
- `packages/better_auth/test/better_auth/plugins/i18n_test.rb` (new).
- `packages/better_auth/test/better_auth/plugin_loader_test.rb`.
- `packages/better_auth/test/better_auth/plugins/upstream_plugin_inventory_test.rb`.
- `packages/better_auth/README.md`.
- `README.md` only if you decide the root supported-feature summary needs an
  i18n mention.
- `docs-site/content/docs/plugins/i18n.mdx` (new).
- `docs-site/content/docs/plugins/meta.json`.
- `docs-site/content/docs/plugins/index.mdx`.
- `docs-site/content/docs/concepts/plugins.mdx`.
- `docs-site/lib/plugins.ts`.

**Out of scope**:

- Creating `packages/better_auth-i18n` or `packages/openauth-i18n`.
- Adding runtime dependencies or changing gemspec dependencies.
- Adding database schema, migrations, endpoints, adapters, or framework
  integration packages.
- Implementing upstream `i18nClient`; RubyAuth has no browser client plugin
  layer and docs already say frontends call HTTP routes.
- Changing global `APIError` response shape outside requests using the i18n
  plugin.
- Touching `reference/upstream-src/**`.
- Reworking docs-site UI components beyond the plugin listing metadata.

## Git workflow

- Branch: `feat/i18n-plugin`.
- Commit message: `feat(core): add i18n plugin`.
- Do not push, open a PR, or commit unless the operator asks.
- This repo currently has unrelated working-tree changes, including deleted
  historical plan files. Do not restore or revert unrelated files.

## Steps

### Step 1: Add the core i18n plugin file

Create `packages/better_auth/lib/better_auth/plugins/i18n.rb`.

Match existing plugin style:

- Start with `# frozen_string_literal: true`.
- Define methods under `module BetterAuth; module Plugins; module_function`.
- Return `BetterAuth::Plugin.new(id: "i18n", hooks: {after: [...]}, options: config)`.
- Register no endpoints, schema, migrations, middleware, rate limits, adapter,
  or error codes.

Do not call `normalize_hash` on the full `translations` tree, because locale
keys and error-code keys must preserve their public meaning. Instead, implement
small option helpers that accept Ruby snake_case and upstream camelCase:

- `translations` (required): Hash keyed by locale string/symbol. Store locale
  keys as strings exactly as given. Store nested error-code keys as uppercase
  strings with `tr("-", "_")`.
- `default_locale` / `defaultLocale`: optional string.
- `detection`: array of strings/symbols. Store values as strings:
  `"header"`, `"cookie"`, `"session"`, `"callback"`.
- `locale_cookie` / `localeCookie`: default `"locale"`.
- `user_locale_field` / `userLocaleField`: default `"locale"`.
- `get_locale` / `getLocale`: optional callable.

Validation and defaults:

- Raise `BetterAuth::Error` with the upstream message substring
  `"i18n plugin: translations object is empty"` when `translations` is missing
  or empty.
- Choose `default_locale` in this exact order:
  1. explicit default locale if it exists in `translations`;
  2. `"en"` if translations include `"en"`;
  3. first locale key in the translations hash.
- Default detection is `["header"]`.

Implement locale detection:

- Header strategy: read `ctx.headers["accept-language"]`; parse comma-separated
  entries; default q to `1`; sort descending by q; map locale tags to base
  locale by splitting on `"-"`; pick the first available locale.
- Cookie strategy: use `ctx.get_cookie(config[:locale_cookie])`; accept only if
  it exists in translations.
- Session strategy: read `(ctx.context.current_session || ctx.context.new_session)`
  and then its `:user` / `"user"` hash; read `config[:user_locale_field]` using
  string, symbol, and snake_case/camelCase forms; accept only available locales.
- Callback strategy: call `config[:get_locale].call(ctx)` if callable; accept
  only available locales. It must be called even when `ctx.request` is `nil`
  for direct `auth.api` calls.
- If no strategy returns an available locale, return `default_locale`.

Implement error translation:

- In the after hook, return `nil` unless `ctx.returned.is_a?(BetterAuth::APIError)`.
- Determine a translation code:
  1. if `error.body` is a hash with `code`, use that;
  2. if `error.code` is not the same as `error.status`, use `error.code`;
  3. otherwise reverse lookup `error.message` against `BetterAuth::BASE_ERROR_CODES`
     merged with every `ctx.context.options.plugins.flat_map(&:error_codes)`.
- If no translation exists for the detected locale and code, return `nil` so
  the original error is unchanged.
- If a translation exists, raise a new `BetterAuth::APIError` preserving
  `error.status` and `error.headers`, with `message` set to the translated
  message and `body` set to:

```ruby
{
  code: error_code,
  message: translation,
  originalMessage: error.message
}
```

Use a symbol key `:originalMessage` so JSON output is `originalMessage`.
Preserve the original HTTP status code.

**Verify**:

```bash
cd packages/better_auth
bundle exec ruby -Itest -Ilib -e 'require "better_auth"; plugin = BetterAuth::Plugins.i18n(translations: { "en" => { "INVALID_EMAIL_OR_PASSWORD" => "Invalid" } }); raise unless plugin.id == "i18n"; raise unless plugin.endpoints.empty?'
```

Expected: exit 0.

### Step 2: Register lazy loading

Update `packages/better_auth/lib/better_auth/plugin_loader.rb`:

- Add `i18n: "plugins/i18n"` to `PLUGIN_FILES`.
- Add `"i18n" => :i18n` to `PLUGIN_ID_TO_LOADER`.
- Do not add i18n to `BOOT_PLUGINS`.
- Do not add i18n to `EXTERNAL_PLUGIN_IMPLEMENTATIONS`.
- Do not add dependencies in `PLUGIN_DEPENDENCIES`.

Update `packages/better_auth/test/better_auth/plugin_loader_test.rb`:

- Extend `BOOT_SCRIPT` with `i18n: BetterAuth::Plugins.plugin_loaded?(:i18n)`.
- In `test_core_boot_loads_open_api_but_not_other_plugins`, assert i18n is
  `"false"`.
- Add an isolated script test that calls
  `BetterAuth::Plugins.i18n(translations: {"en" => {"INVALID_EMAIL_OR_PASSWORD" => "Invalid"}})`
  and asserts `plugin_loaded?(:i18n)` is true and the return value is a
  `BetterAuth::Plugin`.

**Verify**:

```bash
cd packages/better_auth
bundle exec ruby -Itest -Ilib test/better_auth/plugin_loader_test.rb
```

Expected: exit 0.

### Step 3: Add exhaustive server-only i18n tests

Create `packages/better_auth/test/better_auth/plugins/i18n_test.rb`.

Use Minitest, `require_relative "../../test_helper"`, and the existing helper
patterns from:

- `packages/better_auth/test/support/auth_test_helpers.rb`.
- `packages/better_auth/test/better_auth/routes/sign_in_test.rb`.
- `packages/better_auth/test/better_auth/api_test.rb`.

Use ASCII test translations to keep the file encoding simple:

```ruby
TRANSLATIONS = {
  "en" => {
    "INVALID_EMAIL_OR_PASSWORD" => "Invalid email or password",
    "INVALID_PASSWORD" => "Invalid password"
  },
  "fr" => {
    "INVALID_EMAIL_OR_PASSWORD" => "FR invalid email or password",
    "INVALID_PASSWORD" => "FR invalid password",
    "BODY_MUST_BE_AN_OBJECT" => "FR body must be an object",
    "CUSTOM_ERROR" => "FR custom error"
  },
  "de" => {
    "INVALID_EMAIL_OR_PASSWORD" => "DE invalid email or password"
  }
}.freeze
```

Build auth with fast password callbacks to keep tests cheap:

```ruby
def build_auth(options = {})
  BetterAuthTestHelpers.build_auth({
    email_and_password: BetterAuthTestPasswordHelpers.fast_email_and_password_config
  }.merge(options))
end
```

Required tests:

1. Factory shape: id `"i18n"`, no endpoints, no schema, no migrations, options
   include default detection `["header"]`.
2. Empty or missing translations raises `BetterAuth::Error` with
   `"i18n plugin: translations object is empty"`.
3. Header detection translates `INVALID_EMAIL_OR_PASSWORD` to French and
   returns JSON body `{code, message, originalMessage}` for
   `auth.api.sign_in_email(..., headers: {"Accept-Language" => "fr"}, as_response: true)`.
4. Header detection translates to German for `"de"`.
5. `Accept-Language: "es;q=0.9, fr;q=0.8, en;q=0.7"` chooses French because
   Spanish is unavailable.
6. `Accept-Language: "fr-CA"` maps to `"fr"`.
7. Unknown header locale falls back to default locale. Use `default_locale: "de"`
   and assert German translation.
8. Cookie detection with `detection: ["cookie", "header"]` and
   `locale_cookie: "lang"` uses `Cookie: "lang=fr"` even when
   `Accept-Language` is `"de"`.
9. Session detection with `detection: ["session", "header"]` and
   `user_locale_field: "locale"`:
   - configure `user.additional_fields.locale`;
   - sign up a user with `locale: "fr"`;
   - call a protected endpoint that loads current session and then errors,
     for example `auth.api.update_user(headers: {"cookie" => cookie}, body: ["not-object"], as_response: true)`;
   - assert `BODY_MUST_BE_AN_OBJECT` is translated to French.
10. Callback detection reads a custom header with
    `get_locale: ->(ctx) { ctx.headers["x-custom-locale"] }`.
11. Callback detection is called for direct `auth.api` without a request object:
    `get_locale: ->(_ctx) { "fr" }`.
12. Detection order falls through when callback returns an unavailable locale:
    `detection: ["callback", "header"]`, callback returns `"es"`, header is
    `"fr"`, assert French.
13. Missing translation for a detected locale keeps the original response
    unchanged and does not add `originalMessage`. Use a code absent from the
    locale dictionary.
14. Non-error responses are not modified. Sign up or sign in, then call
    `auth.api.get_session(..., headers: {"Accept-Language" => "fr"}, as_response: true)`
    and assert the response has `session` and `user` but no `originalMessage`.
15. Rack HTTP request path translates the same way as direct API:
    call `auth.call(BetterAuthTestHelpers.json_rack_env("POST", "/api/auth/sign-in/email", body: {email: "missing@example.com", password: "password123"}, headers: {"HTTP_ACCEPT_LANGUAGE" => "fr"}))`.
16. Symbol and camelCase option compatibility:
    `translations: {fr: {INVALID_PASSWORD: "FR invalid password"}}`,
    `defaultLocale: "fr"`, `localeCookie: "lang"`, `userLocaleField: "locale"`,
    `getLocale: ->(_ctx) { "fr" }`.
17. Plugin error-code reverse lookup: define a custom plugin with
    `error_codes: {"CUSTOM_ERROR" => "Custom original"}` and an endpoint that
    raises `APIError.new("BAD_REQUEST", message: "Custom original")`; assert
    i18n translates using `CUSTOM_ERROR`.
18. Direct API without `as_response` raises a translated `BetterAuth::APIError`
    whose `message` is translated and whose `body[:originalMessage]` is the
    original English message.

Keep tests server-only. Do not introduce JS client tests or browser tooling.

**Verify**:

```bash
cd packages/better_auth
bundle exec ruby -Itest -Ilib test/better_auth/plugins/i18n_test.rb
```

Expected: exit 0 and at least 18 test methods.

### Step 4: Update plugin inventory tests

Update `packages/better_auth/test/better_auth/plugins/upstream_plugin_inventory_test.rb`:

- Add `BetterAuth::Plugins.i18n(translations: {"en" => {"INVALID_EMAIL_OR_PASSWORD" => "Invalid email or password"}})` to the hook-only plugin list in
  `test_upstream_hook_only_plugins_do_not_register_http_endpoints`.
- No external shim exemption is needed because `i18n_test.rb` will be a direct
  owner.

**Verify**:

```bash
cd packages/better_auth
bundle exec ruby -Itest -Ilib test/better_auth/plugins/upstream_plugin_inventory_test.rb
```

Expected: exit 0.

### Step 5: Document the Ruby API

Update `packages/better_auth/README.md` with a short `### i18n` subsection near
the plugin-related feature examples. Include a Ruby example:

```ruby
auth = BetterAuth.auth(
  secret: ENV.fetch("BETTER_AUTH_SECRET"),
  database: :memory,
  plugins: [
    BetterAuth::Plugins.i18n(
      translations: {
        "fr" => {
          "INVALID_EMAIL_OR_PASSWORD" => "Identifiants invalides"
        }
      },
      detection: ["cookie", "header"],
      locale_cookie: "lang"
    )
  ]
)
```

State that this is server-side only: clients receive translated error JSON from
the existing HTTP routes; there is no Ruby browser client plugin.

Optionally update root `README.md` if its supported-feature summary would
otherwise imply i18n is still unsupported.

**Verify**:

```bash
bundle exec standardrb packages/better_auth/README.md
```

Expected: If StandardRB ignores Markdown, exit 0. If it rejects a Markdown path,
do not fight the tool; run the full core lint command from the Commands table
instead.

### Step 6: Add docs-site page and navigation

Read `docs-site/AGENTS.md` before editing docs. Then:

- Create `docs-site/content/docs/plugins/i18n.mdx`.
- Use Ruby examples, not TypeScript.
- Do not include `<UnderDevelopment />` if all server-side behavior in this
  plan is implemented and tested.
- Cover:
  - installation: no extra gem, included in `better_auth`;
  - error response format with `code`, translated `message`, `originalMessage`;
  - detection strategies `header`, `cookie`, `session`, `callback`;
  - options `translations`, `default_locale`, `detection`, `locale_cookie`,
    `user_locale_field`, `get_locale`;
  - fallback behavior;
  - server-only note: no `i18nClient` equivalent.

Update navigation and plugin listing:

- `docs-site/content/docs/plugins/meta.json`: add `"i18n"` in a sensible place
  under utility/core plugins, near `last-login-method` or `open-api`.
- `docs-site/content/docs/plugins/index.mdx`: add i18n to the core plugin list
  and remove i18n from the upstream-only exclusion sentence.
- `docs-site/content/docs/concepts/plugins.mdx`: add i18n to the built-in
  plugin table if that table remains a curated list.
- `docs-site/lib/plugins.ts`: add metadata for slug `"i18n"` with category
  `"Utility"`, icon `"Languages"` if available in the app icon set, otherwise
  `"Globe"`, and tagline `"Translate server error messages by locale"`.

**Verify**:

```bash
cd docs-site
pnpm lint
pnpm build
```

Expected: both commands exit 0.

### Step 7: Run package and workspace verification

Run focused checks first, then broader checks:

```bash
cd packages/better_auth
bundle exec ruby -Itest -Ilib test/better_auth/plugins/i18n_test.rb
bundle exec ruby -Itest -Ilib test/better_auth/plugin_loader_test.rb
bundle exec ruby -Itest -Ilib test/better_auth/plugins/upstream_plugin_inventory_test.rb
bundle exec rake test
bundle exec standardrb lib/better_auth/plugins/i18n.rb lib/better_auth/plugin_loader.rb test/better_auth/plugins/i18n_test.rb test/better_auth/plugin_loader_test.rb test/better_auth/plugins/upstream_plugin_inventory_test.rb
```

From the repo root:

```bash
bundle exec rake ci
```

Expected: all commands exit 0. If workspace CI fails in unrelated dirty
docs-site files, capture the failing paths and report them; do not revert
unrelated work.

## Test plan

New primary test file:

- `packages/better_auth/test/better_auth/plugins/i18n_test.rb`.

Use these existing files as structural patterns:

- `packages/better_auth/test/better_auth/plugins/last_login_method_test.rb` for
  hook-only plugin tests and fast email/password route flows.
- `packages/better_auth/test/better_auth/api_test.rb` for after-hook error
  behavior and direct API `as_response` assertions.
- `packages/better_auth/test/support/auth_test_helpers.rb` for Rack env helpers
  and cookie parsing.

Minimum coverage:

- All upstream server-applicable tests from
  `reference/upstream-src/1.6.9/repository/packages/i18n/src/i18n.test.ts`.
- Ruby-specific adaptation for reverse error-code lookup from
  `APIError#message`.
- Direct API and Rack HTTP response paths.
- Lazy loading and plugin inventory ownership.

## Done criteria

All must hold:

- [ ] `BetterAuth::Plugins.i18n` exists and returns a hook-only
  `BetterAuth::Plugin` with id `"i18n"`.
- [ ] No new package, gemspec dependency, endpoint, migration, schema, or
  adapter is added.
- [ ] `Accept-Language`, cookie, session, and callback locale detection work in
  configured priority order.
- [ ] Empty translations raise a clear `BetterAuth::Error`.
- [ ] Fallback locale order matches upstream: explicit valid default, then
  `"en"`, then first translations key.
- [ ] Translated errors preserve HTTP status and response headers.
- [ ] Translated response bodies include `code`, translated `message`, and
  `originalMessage`.
- [ ] Missing translations and non-error responses are unchanged.
- [ ] Direct `auth.api` without a Rack request still supports `get_locale`.
- [ ] `packages/better_auth/test/better_auth/plugins/i18n_test.rb` has at least
  18 tests and passes.
- [ ] Plugin loader and upstream plugin inventory tests pass.
- [ ] `cd packages/better_auth && bundle exec rake test` exits 0.
- [ ] `cd packages/better_auth && bundle exec standardrb ...` exits 0 for the
  touched Ruby files.
- [ ] `cd docs-site && pnpm lint` and `cd docs-site && pnpm build` exit 0, or
  unrelated pre-existing docs failures are reported with paths.
- [ ] `plans/README.md` status row for plan 019 is updated.

## STOP conditions

Stop and report back if:

- `API#run_after_hooks` no longer exposes `ctx.returned` as an `APIError`; this
  plan relies on that hook contract.
- You need to change global `APIError#to_h` or dozens of route error
  constructors to make i18n work.
- Implementing session detection requires a new database field outside existing
  `user.additional_fields`.
- Any implementation path requires a new gem dependency.
- Docs-site has moved away from MDX files under `docs-site/content/docs`.
- A verification command fails twice after a reasonable fix attempt.

## Maintenance notes

- Future upstream i18n changes should be compared against
  `reference/upstream-src/<version>/repository/packages/i18n/src/index.ts` and
  `i18n.test.ts`.
- Reviewers should scrutinize error-code inference. It must be scoped to the
  i18n plugin so existing non-i18n response shapes remain stable.
- If RubyAuth later adds a browser client package, revisit the upstream
  `i18nClient` stub. Until then, it is intentionally out of scope.
- If new plugins add their own `error_codes`, i18n should automatically pick
  them up through `ctx.context.options.plugins`.
