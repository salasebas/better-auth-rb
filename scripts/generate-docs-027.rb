#!/usr/bin/env ruby
# frozen_string_literal: true

# Generator for plan 027 — reference section and surviving guides.

require "fileutils"

ROOT = File.expand_path("..", __dir__)
REF = File.join(ROOT, "docs-site/content/docs/reference")
ERR = File.join(REF, "errors")
GUIDES = File.join(ROOT, "docs-site/content/docs/guides")

def write(path, content)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, content)
  puts "wrote #{path}"
end

EMITTED_ERRORS = {
  "state_mismatch" => {
    title: "State Mismatch",
    when: "The OAuth state cookie does not match the `state` query parameter on callback.",
    causes: ["Expired or missing state cookie", "User opened callback in a different browser", "Cookie blocked or wrong domain"],
    fixes: ["Ensure cookies work on your auth domain", "Do not open OAuth callbacks in private windows without cookies", "Check `trusted_origins` includes your frontend URL"]
  },
  "state_not_found" => {
    title: "State Not Found",
    when: "OAuth callback arrived without valid stored OAuth state.",
    causes: ["State cookie expired (10 minute default)", "Session cleared mid-flow", "Multiple auth mounts with mismatched cookie paths"],
    fixes: ["Retry sign-in from the beginning", "Verify single `better_auth` mount per app", "Check cookie `SameSite` and domain settings"]
  },
  "no_code" => {
    title: "No Code",
    when: "Provider redirected back without an authorization `code`.",
    causes: ["User denied consent", "Provider misconfiguration", "Wrong redirect URI registered"],
    fixes: ["Confirm redirect URI matches `{BETTER_AUTH_URL}/api/auth/callback/{provider}`", "Check provider console for errors"]
  },
  "invalid_code" => {
    title: "Invalid Code",
    when: "Authorization code exchange with the provider failed.",
    causes: ["Code already used", "Clock skew", "Wrong client secret", "PKCE verifier mismatch"],
    fixes: ["Verify `client_id` and `client_secret`", "For Google/Vercel, ensure PKCE flow completes in one browser session"]
  },
  "oauth_provider_not_found" => {
    title: "OAuth Provider Not Found",
    when: "Callback `providerId` is not configured in `social_providers`.",
    causes: ["Typo in provider id", "Plugin provider not loaded", "Stale callback URL from old config"],
    fixes: ["Match callback segment to configured provider id", "Restart app after changing `social_providers`"]
  },
  "email_not_found" => {
    title: "Email Not Found",
    when: "Provider user profile did not include an email address.",
    causes: ["Provider scope missing email", "Account privacy settings", "Enterprise IdP omitting email claim"],
    fixes: ["Request `email` scope from provider", "Use a provider that returns email for your tenant"]
  },
  "email_doesn't_match" => {
    title: "Email Doesn't Match",
    when: "Linking a social account but provider email differs from signed-in user.",
    causes: ["User signed in with different email than OAuth profile", "Account linking rules enforced"],
    fixes: ["Sign in with matching email first", "Review `account.account_linking` options in configuration"]
  },
  "unable_to_get_user_info" => {
    title: "Unable To Get User Info",
    when: "Token exchange succeeded but user profile could not be fetched.",
    causes: ["Revoked tokens", "Provider API outage", "Missing userinfo scope"],
    fixes: ["Check provider status", "Verify scopes include profile/email", "Inspect server logs for provider HTTP errors"]
  },
  "unable_to_link_account" => {
    title: "Unable To Link Account",
    when: "Account linking is not allowed for this provider or email.",
    causes: ["Implicit sign-up disabled for provider", "Linking rules block provider", "Email domain restricted"],
    fixes: ["Enable linking in account options", "Use explicit link flow while authenticated"]
  },
  "account_not_linked" => {
    title: "Account Not Linked",
    when: "Existing user tried OAuth sign-in but account is not linked to that provider.",
    causes: ["User previously signed up with email/password only", "Linking required before OAuth sign-in"],
    fixes: ["Sign in with email/password then link provider", "Enable implicit linking if appropriate for your app"]
  },
  "account_already_linked_to_different_user" => {
    title: "Account Already Linked To Different User",
    when: "Provider account is linked to another user in your database.",
    causes: ["Shared OAuth account across users", "Stale test data"],
    fixes: ["Unlink from other user via admin tools", "Use separate provider apps for staging"]
  },
  "signup_disabled" => {
    title: "Signup Disabled",
    when: "OAuth attempted to create a new user but sign-up is disabled.",
    causes: ["`disableSignUp` on provider or global policy", "Invite-only app"],
    fixes: ["Create user through admin flow first", "Adjust provider `disable_sign_up` options"]
  },
  "please_restart_the_process" => {
    title: "Please Restart The Process",
    when: "Generic OAuth plugin state validation failed or session expired mid-flow.",
    causes: ["Stale generic OAuth state", "Multiple tabs racing OAuth", "Cookie cleared during flow"],
    fixes: ["Start OAuth from `/api/auth/sign-in/oauth2` again", "Avoid parallel OAuth attempts"]
  },
  "unknown" => {
    title: "Unknown",
    when: "Unhandled OAuth error slug or provider-returned error.",
    causes: ["Provider sent unexpected error query param", "Custom plugin error"],
    fixes: ["Check `error_description` query param", "Inspect server logs", "Run `bundle exec better-auth doctor`"]
  }
}.freeze

UPSTREAM_ONLY_ERRORS = %w[
  unable_to_create_user
  unable_to_create_session
  invalid_callback_request
  no_callback_url
  internal_server_error
].freeze

def error_mdx(slug, meta)
  <<~MDX
    ---
    title: #{meta[:title]}
    description: OAuth error `#{slug}` in RubyAuth.
    ---

    ## When this appears

    #{meta[:when]}

    Redirect URL shape:

    ```
    /api/auth/error?error=#{slug}
    ```

    Or your configured `errorCallbackURL` with the same query parameters.

    ## Common causes

    #{meta[:causes].map { |c| "- #{c}" }.join("\n")}

    ## How to fix

    #{meta[:fixes].map { |f| "- #{f}" }.join("\n")}

    ## Diagnostics

    ```bash
    bundle exec better-auth doctor --cwd . --config config/better_auth.rb
    ```

    ## Related

    - [OAuth errors index](/docs/reference/errors)
    - [OAuth concepts](/docs/concepts/oauth)
  MDX
end

def upstream_only_error_mdx(slug)
  title = slug.tr("_", " ").split.map(&:capitalize).join(" ")
  <<~MDX
    ---
    title: #{title}
    description: Upstream OAuth error slug — not emitted by RubyAuth redirects.
    ---

    <Callout type="info" title="RubyAuth note">
      RubyAuth does not emit this OAuth redirect slug. Similar failures may appear as JSON API errors from `BetterAuth::APIError` instead. See [options](/docs/reference/options#on-api-error) for `on_api_error` configuration.
    </Callout>

    This page documents an upstream Better Auth error slug kept for bookmark compatibility. If you see auth failures with related symptoms, check server logs and API error codes rather than this redirect query parameter.

    ## Related

    - [OAuth errors index](/docs/reference/errors)
    - [FAQ](/docs/reference/faq)
  MDX
end

EMITTED_ERRORS.each do |slug, meta|
  write(File.join(ERR, "#{slug}.mdx"), error_mdx(slug, meta))
end

UPSTREAM_ONLY_ERRORS.each do |slug|
  write(File.join(ERR, "#{slug}.mdx"), upstream_only_error_mdx(slug))
end

write(File.join(ERR, "index.mdx"), <<~MDX)
  ---
  title: Errors
  description: OAuth redirect errors and troubleshooting in RubyAuth.
  ---

  Social and generic OAuth flows redirect to `/api/auth/error` (or your `errorCallbackURL`) with an `error` query parameter when sign-in fails.

  ## RubyAuth redirect errors

  #{EMITTED_ERRORS.keys.sort.map { |s| "* [#{EMITTED_ERRORS[s][:title]}](/docs/reference/errors/#{s})" }.join("\n")}

  ## Upstream-only slugs

  These slugs exist in upstream Better Auth docs but are **not** emitted by RubyAuth OAuth redirects:

  #{UPSTREAM_ONLY_ERRORS.map { |s| "* [#{s.tr("_", " ").split.map(&:capitalize).join(" ")}](/docs/reference/errors/#{s})" }.join("\n")}

  For API JSON errors, configure [`on_api_error`](/docs/reference/options#on-api-error) and inspect `BetterAuth::APIError` in server logs.
MDX

write(File.join(REF, "options.mdx"), <<~MDX)
  ---
  title: Options
  description: RubyAuth configuration options for BetterAuth.auth and BetterAuth::Rails.configure.
  ---
  
  <RubyAuthDisclaimer />
  
  RubyAuth configuration maps to `BetterAuth::Configuration` in the core gem. Pass options to `BetterAuth.auth(...)` or `BetterAuth::Rails.configure`.
  
  ## Quick example
  
  ```ruby
  BetterAuth.auth(
    app_name: "My App",
    base_url: ENV.fetch("BETTER_AUTH_URL"),
    base_path: "/api/auth",
    secret: ENV.fetch("BETTER_AUTH_SECRET"),
    database: :postgres,
    trusted_origins: [ENV.fetch("BETTER_AUTH_URL")],
    email_and_password: { enabled: true },
    password_hasher: :scrypt,
    session: { expires_in: 60 * 60 * 24 * 7 },
    rate_limit: { enabled: true },
    social_providers: {},
    plugins: []
  )
  ```
  
  Rails:
  
  ```ruby
  BetterAuth::Rails.configure do |config|
    config.secret = ENV.fetch("BETTER_AUTH_SECRET")
    config.base_url = ENV.fetch("BETTER_AUTH_URL")
    config.database = :postgres
  end
  ```
  
  ## app_name
  
  Application name used in emails, TOTP issuer labels, and telemetry project id derivation. Default: `"Better Auth"`.
  
  ## base_url
  
  Public URL of your auth deployment. String form:
  
  ```ruby
  base_url: "https://auth.example.com"
  ```
  
  Dynamic form for preview deployments — see [Dynamic base URL guide](/docs/guides/dynamic-base-url):
  
  ```ruby
  base_url: {
    allowed_hosts: ["myapp.com", "*.vercel.app", "localhost:3000"],
    protocol: "https",
    fallback: "https://myapp.com"
  }
  ```
  
  ## base_path
  
  Mount path prefix for auth routes. Default: `"/api/auth"`.
  
  ## secret and secrets
  
  `secret` — signing key for cookies and tokens. Required in production (32+ chars). Generate with `bundle exec better-auth secret`.
  
  `secrets` — optional rotation config via `BETTER_AUTH_SECRETS` env or hash for multi-secret verification.
  
  ## trusted_origins
  
  Array of allowed origins for CSRF/origin checks and redirect validation:
  
  ```ruby
  trusted_origins: ["http://localhost:3000", "https://app.example.com"]
  ```
  
  Can be a callable for dynamic origin lists.
  
  ## database
  
  Dialect symbol (`:postgres`, `:mysql`, `:sqlite`, `:mssql`, `:memory`) or adapter lambda returning `BetterAuth::Adapters::*`. See [adapters](/docs/adapters/postgresql).
  
  ## secondary_storage
  
  Optional Redis or custom secondary storage for sessions/rate limits. Requires explicit adapter configuration.
  
  <UnderDevelopment>
    Secondary storage parity varies by deployment — verify with `bundle exec better-auth doctor`.
  </UnderDevelopment>
  
  ## session
  
  ```ruby
  session: {
    expires_in: 60 * 60 * 24 * 7,
    update_age: 60 * 60 * 24,
    fresh_age: 60 * 60 * 24,
    cookie_cache: { enabled: true, max_age: 300, strategy: "jwe" }
  }
  ```
  
  ## account
  
  Account linking, OAuth token storage, and `update_account_on_sign_in` behavior.
  
  ## user
  
  ```ruby
  user: {
    additional_fields: {
      role: { type: "string", default_value: "member" }
    }
  }
  ```
  
  ## verification
  
  Email verification token lifetime and send behavior. Works with `email_verification` callbacks.
  
  ## email_and_password
  
  ```ruby
  email_and_password: {
    enabled: true,
    require_email_verification: false,
    min_password_length: 8,
    max_password_length: 128
  }
  ```
  
  ## password_hasher
  
  `:scrypt` (default) or `:bcrypt`. RubyAuth does not accept arbitrary JavaScript hash functions.
  
  ## email_verification
  
  Mailer callbacks: `send_verification_email`, `send_on_sign_up`, `auto_sign_in_after_verification`.
  
  ## social_providers
  
  Hash of provider id => factory result:
  
  ```ruby
  social_providers: {
    github: BetterAuth::SocialProviders.github(
      client_id: ENV.fetch("GITHUB_CLIENT_ID"),
      client_secret: ENV.fetch("GITHUB_CLIENT_SECRET")
    )
  }
  ```
  
  ## plugins
  
  Array of plugin instances: `BetterAuth::Plugins.two_factor`, external gems, etc.
  
  ## rate_limit
  
  ```ruby
  rate_limit: {
    enabled: true,
    window: 60,
    max: 100,
    storage: :memory
  }
  ```
  
  ## advanced
  
  IP address headers, secure cookies, default cookie attributes, ID generation overrides.
  
  <UnderDevelopment>
    Upstream `crossSubDomainCookies` / `customizeDefaultErrorPage` theming is not fully ported — use `advanced` keys documented in `configuration.rb` only.
  </UnderDevelopment>
  
  Cross-subdomain cookies can be configured via `advanced.cross_subdomain_cookies` where supported — verify in your environment.
  
  ## hooks and database_hooks
  
  Request hooks (`before`/`after`) and adapter-level record transforms. See [Hooks](/docs/concepts/hooks).
  
  ## on_api_error
  
  <span id="on-api-error" />
  
  ```ruby
  on_api_error: {
    error_url: "/api/auth/error",
    throw: false
  }
  ```
  
  ## disabled_paths
  
  Disable specific routes by path string.
  
  ## telemetry
  
  ```ruby
  telemetry: { enabled: false }
  ```
  
  See [Telemetry](/docs/reference/telemetry) and `gem "better_auth-telemetry"`.
  
  ## logger
  
  Ruby `Logger` instance for auth internals.
  
  ## experimental
  
  Experimental flags — subject to change between releases.
  
  ## Related
  
  - [Installation](/docs/installation)
  - [Security](/docs/reference/security)
  - [Dynamic base URL](/docs/guides/dynamic-base-url)
MDX

write(File.join(REF, "security.mdx"), <<~MDX)
  ---
  title: Security
  description: Security defaults and hardening in RubyAuth.
  ---

  <RubyAuthDisclaimer />

  ## Secrets

  - Set `BETTER_AUTH_SECRET` with high entropy (`bundle exec better-auth secret`)
  - Never commit secrets; use Rails credentials or environment variables
  - Optional `BETTER_AUTH_SECRETS` for rotation

  ## Origin and CSRF

  RubyAuth validates trusted origins on mutating routes. Configure `trusted_origins` to include every frontend origin that calls auth APIs.

  Fetch Metadata / origin checks are enforced in the Rack router — see core router tests.

  ## Session cookies

  Default cookie prefix: `better-auth.session_token`. Cookies are `HttpOnly`. `Secure` is enabled for HTTPS `base_url` or production environments.

  See [Cookies](/docs/concepts/cookies) and `BetterAuth::Cookies`.

  ## Password hashing

  Default hasher: **scrypt** (`password_hasher: :scrypt`). Alternative: `:bcrypt`.

  Use the [Have I Been Pwned](/docs/plugins/have-i-been-pwned) plugin to reject breached passwords.

  ## Rate limiting

  Enable `rate_limit: { enabled: true }` to throttle auth endpoints. Use shared storage in multi-process deployments.

  ## HTTPS

  Always use HTTPS in production. Set `BETTER_AUTH_URL` to the public HTTPS URL so OAuth redirect URIs match provider consoles.

  ## Related

  - [Options](/docs/reference/options)
  - [Security-focused plugins](/docs/plugins/captcha)
MDX

write(File.join(REF, "telemetry.mdx"), <<~MDX)
  ---
  title: Telemetry
  description: Opt-in telemetry with the better_auth-telemetry gem.
  ---

  Telemetry is **disabled by default** in RubyAuth. It is not a plugin — install the optional gem:

  ```ruby
  gem "better_auth-telemetry"
  ```

  When bundled, core soft-loads a publisher on `auth.telemetry`. Without the gem, `#publish` is a safe no-op.

  ## Opt in

  ```ruby
  BetterAuth.auth(
    telemetry: { enabled: true }
  )
  ```

  Or via environment:

  ```bash
  export BETTER_AUTH_TELEMETRY=1
  export BETTER_AUTH_TELEMETRY_ENDPOINT=https://telemetry.example.com/ingest
  ```

  Explicit `telemetry: { enabled: false }` overrides env vars.

  ## Debug mode

  ```ruby
  telemetry: { enabled: true, debug: true }
  ```

  Logs JSON events locally — no HTTP requests.

  ## Ruby-specific behavior

  - Detects Ruby frameworks (Rails, Sinatra, Hanami, Roda, Grape) via `Gem.loaded_specs`
  - Reports Bundler as package manager, not npm
  - Skipped automatically in test environments (`RACK_ENV=test`, etc.)

  See `packages/better_auth-telemetry/README.md` for full env var table and redaction rules.

  ## Related

  - [Options — telemetry](/docs/reference/options#telemetry)
MDX

write(File.join(REF, "instrumentation.mdx"), <<~MDX)
  ---
  title: Instrumentation
  description: Tracing hooks in RubyAuth (noop by default).
  ---

  <UnderDevelopment>
    OpenTelemetry is not wired in RubyAuth yet. The `BetterAuth::Instrumentation` module exposes a noop tracer API for future exporters.
  </UnderDevelopment>

  Core defines:

  ```ruby
  BetterAuth::Instrumentation.with_span("operation.name", attributes: { foo: "bar" }) do |span|
    span.set_attribute("key", "value")
  end
  ```

  Spans are no-ops today — safe to call but produce no exported traces.

  For production observability, use application-level logging around `auth.api` calls and Rack middleware until OTel integration lands.

  ## Related

  - [Telemetry](/docs/reference/telemetry)
MDX

write(File.join(REF, "faq.mdx"), <<~MDX)
  ---
  title: FAQ
  description: Frequently asked questions about RubyAuth.
  ---

  <RubyAuthDisclaimer />

  ## Is RubyAuth the same as Better Auth?

  No. RubyAuth is an independent Ruby server library inspired by Better Auth v1.6.9. It is not the official npm package or hosted service.

  ## Is there a JavaScript client?

  No official browser client gem. Frontends call `/api/auth/*` over HTTP with cookies or bearer tokens. External API-key docs note upstream JS client plugins can talk to the Ruby server.

  ## How do I mount auth in Rails?

  Add `better_auth-rails`, run `bin/rails generate better_auth:install`, and add `better_auth` to routes. See [Rails integration](/docs/integrations/rails).

  ## How do I generate a secret?

  ```bash
  bundle exec better-auth secret
  ```

  Set `BETTER_AUTH_SECRET` in the environment.

  ## Which databases are supported?

  PostgreSQL, MySQL, SQLite, SQL Server, in-memory, and MongoDB (via `better_auth-mongodb`). Rails uses ActiveRecord; Hanami uses Sequel.

  ## How do migrations work?

  ```bash
  bundle exec better-auth generate --cwd . --dialect postgres --output db/better_auth/schema.sql
  bundle exec better-auth migrate --cwd . --config config/better_auth.rb --yes
  ```

  ## How do I read the session server-side?

  ```ruby
  auth.api.get_session(headers: { "cookie" => request.env["HTTP_COOKIE"] })
  ```

  Or use framework helpers (`current_user` in Rails/Sinatra/Roda/Grape).

  ## Why do OAuth redirects fail with state_mismatch?

  Usually cookie or origin issues. See [State mismatch](/docs/reference/errors/state_mismatch).

  ## How do I disable sign-up?

  Configure provider or global sign-up disable options; OAuth returns `signup_disabled` when blocked.

  ## Where are plugin options documented?

  [Plugins index](/docs/plugins) and individual plugin pages.

  ## How do I contribute?

  See [Contributing](/docs/reference/contributing).

  ## Related

  - [Installation](/docs/installation)
  - [Options](/docs/reference/options)
MDX

write(File.join(REF, "contributing.mdx"), <<~MDX)
  ---
  title: Contributing
  description: Contribute to the RubyAuth monorepo.
  ---

  RubyAuth lives in the [better-auth Ruby monorepo](https://github.com/salasebas/better-auth-rb). Upstream TypeScript Better Auth is used as a behavioral reference, not as code to copy directly.

  ## Development setup

  ```bash
  git clone https://github.com/salasebas/better-auth-rb.git
  cd better-auth-rb
  bundle install
  ```

  ## Tests

  Core gem (Minitest):

  ```bash
  bundle exec rake test
  ```

  Full workspace CI:

  ```bash
  bundle exec rake ci
  ```

  Adapter and plugin packages use RSpec in their directories.

  ## Linting

  ```bash
  bundle exec standardrb
  ```

  Core and docs follow Standard Ruby style with `# frozen_string_literal: true`.

  ## Parity work

  Before changing auth behavior, read matching upstream tests at `reference/upstream-src/1.6.23/` (fetch with `./scripts/fetch-upstream-better-auth.sh`) and update `packages/better_auth/test/support/upstream_server_parity.rb`.

  ## Docs

  User-facing docs live in `docs-site/`. Update MDX when changing public Ruby APIs.

  ## Related

  - [AGENTS.md](https://github.com/salasebas/better-auth-rb/blob/main/AGENTS.md)
  - [Resources](/docs/reference/resources)
MDX

write(File.join(REF, "resources.mdx"), <<~MDX)
  ---
  title: Resources
  description: Links and resources for RubyAuth.
  ---

  ## Official

  - [GitHub — better-auth-rb](https://github.com/salasebas/better-auth-rb)
  - [Documentation](/docs/introduction)
  - [LLMs.txt](/llms.txt) — machine-readable docs

  ## Gems

  - [better_auth](https://rubygems.org/gems/better_auth) — core
  - [better_auth-rails](https://rubygems.org/gems/better_auth-rails) — Rails integration
  - Extension gems: `better_auth-api-key`, `better_auth-sso`, `better_auth-stripe`, `better_auth-passkey`, `better_auth-mongodb`

  ## Inspiration

  Design inspired by [Better Auth](https://www.better-auth.com) (TypeScript). RubyAuth is a community Ruby port — not affiliated with the upstream project.

  ## Community

  Open issues and discussions on GitHub. For adapter or plugin contributions see [Community plugins](/docs/plugins/community-plugins).

  ## Related

  - [Contributing](/docs/reference/contributing)
  - [FAQ](/docs/reference/faq)
MDX

write(File.join(GUIDES, "dynamic-base-url.mdx"), <<~MDX)
  ---
  title: Dynamic Base URL
  description: Configure RubyAuth for preview deployments and multiple hostnames.
  ---

  Use dynamic `base_url` when your app is served from multiple hostnames (custom domains, preview URLs, branch deploys).

  Configuration lives on the [`base_url` option](/docs/reference/options#base_url).

  ## Basic setup

  ```ruby
  BetterAuth.auth(
    secret: ENV.fetch("BETTER_AUTH_SECRET"),
    base_url: {
      allowed_hosts: [
        "myapp.com",
        "www.myapp.com",
        "*.vercel.app",
        "localhost:3000"
      ],
      protocol: "https",
      fallback: "https://myapp.com"
    },
    database: :postgres
  )
  ```

  RubyAuth reads `x-forwarded-host`, `host`, or the request URL, validates against `allowed_hosts`, and sets a per-request runtime base URL.

  ## Wildcards

  Patterns like `*.vercel.app` match preview subdomains. Keep the list as small as possible.

  ## Trusted origins

  Dynamic hosts are also added to trusted origin inference where configured. Still set explicit `trusted_origins` for frontend apps on different ports during development:

  ```ruby
  trusted_origins: ["http://localhost:5173", "https://myapp.com"]
  ```

  ## Rails

  ```ruby
  BetterAuth::Rails.configure do |config|
    config.base_url = {
      allowed_hosts: ["myapp.com", "*.herokuapp.com"],
      protocol: "https",
      fallback: ENV.fetch("BETTER_AUTH_URL")
    }
  end
  ```

  ## Diagnostics

  Misconfigured allowlists raise at boot: `baseURL.allowedHosts cannot be empty`.

  OAuth redirect mismatches usually mean the resolved host was not in `allowed_hosts` — check provider console redirect URIs against the resolved URL.

  ## Related

  - [Options — base_url](/docs/reference/options#base_url)
  - [Security](/docs/reference/security)
MDX

write(File.join(GUIDES, "saml-sso-with-okta.mdx"), <<~MDX)
  ---
  title: SAML SSO With Okta
  description: Enterprise SSO with Okta via better_auth-sso and better_auth-saml.
  ---

  <RubyAuthDisclaimer />

  Enterprise SAML SSO uses external gems — not the core `better_auth` gem alone.

  ## Gems

  ```ruby
  gem "better_auth-sso"   # SSO orchestration (includes OIDC via better_auth-oidc)
  gem "better_auth-saml"  # SAML identity providers
  ```

  ```ruby
  require "better_auth/sso"
  require "better_auth/saml"

  BetterAuth.auth(
    secret: ENV.fetch("BETTER_AUTH_SECRET"),
    base_url: ENV.fetch("BETTER_AUTH_URL"),
    database: :postgres,
    plugins: [
      BetterAuth::Plugins.sso
    ]
  )
  ```

  See [SSO plugin](/docs/plugins/sso) and `packages/better_auth-sso/README.md`.

  ## Okta setup (high level)

  1. Create a SAML 2.0 app integration in Okta Admin.
  2. Set ACS URL to `{BETTER_AUTH_URL}/api/auth/sso/saml/callback/{providerId}` (verify exact path in SSO plugin docs/tests).
  3. Map Okta attributes to email and name fields required by RubyAuth.
  4. Register the IdP in RubyAuth SSO provider configuration with metadata URL or XML.

  ## Sign-in flow

  Redirect users to the SSO sign-in route exposed by the plugin (see plugin tests for exact path and query params). RubyAuth creates or links users after assertion validation.

  ## OIDC alternative

  If Okta supports OIDC for your tenant, consider generic OAuth presets or the SSO plugin's OIDC path — often simpler than SAML.

  ## Related

  - [SSO plugin](/docs/plugins/sso)
  - [Generic OAuth](/docs/plugins/generic-oauth)
  - [Enterprise plugins](/docs/plugins)
MDX

write(File.join(GUIDES, "optimizing-for-performance.mdx"), <<~MDX)
  ---
  title: Optimizing For Performance
  description: Performance tips for RubyAuth server deployments.
  ---

  RubyAuth runs as a Rack app — optimize the Ruby process, database, and cookie/session strategy.

  ## Database

  - Use PostgreSQL or MySQL in production; avoid `:memory`
  - Index auth tables from generated migrations
  - Place auth DB close to app servers (low latency)

  ## Session cookie cache

  Reduce database reads with encrypted session data cookies:

  ```ruby
  session: {
    cookie_cache: {
      enabled: true,
      max_age: 300,
      strategy: "jwe"
    }
  }
  ```

  See [Session management](/docs/concepts/session-management).

  ## Rate limiting storage

  Use shared storage for rate limits when running multiple Puma/Unicorn workers:

  ```ruby
  rate_limit: {
    enabled: true,
    storage: :memory  # single process only
  }
  ```

  <UnderDevelopment>
    Redis-backed rate limit storage requires explicit adapter wiring — verify with `bundle exec better-auth doctor`.
  </UnderDevelopment>

  ## Secondary storage

  Optional Redis secondary storage can offload hot session data. Configure only when needed and benchmark first.

  ## Keep plugins minimal

  Each plugin adds routes and schema. Enable only plugins you use.

  ## Reverse proxies

  Set `trusted_origins`, forward `X-Forwarded-*` headers correctly, and use HTTPS termination at the load balancer.

  ## Related

  - [Options](/docs/reference/options)
  - [PostgreSQL adapter](/docs/adapters/postgresql)
MDX

puts "done"
