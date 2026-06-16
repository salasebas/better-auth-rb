#!/usr/bin/env ruby
# frozen_string_literal: true

# One-off generator for plan 024 — auth providers and plugin MDX pages.

require "fileutils"

ROOT = File.expand_path("..", __dir__)
AUTH_DIR = File.join(ROOT, "docs-site/content/docs/authentication")
PLUGINS_DIR = File.join(ROOT, "docs-site/content/docs/plugins")

PROVIDER_MAP = {
  "apple" => {factory: "apple", id: "apple", name: "Apple"},
  "atlassian" => {factory: "atlassian", id: "atlassian", name: "Atlassian"},
  "cognito" => {factory: "cognito", id: "cognito", name: "Amazon Cognito", extra: "domain: ENV.fetch(\"COGNITO_DOMAIN\"),"},
  "discord" => {factory: "discord", id: "discord", name: "Discord"},
  "dropbox" => {factory: "dropbox", id: "dropbox", name: "Dropbox"},
  "facebook" => {factory: "facebook", id: "facebook", name: "Facebook"},
  "figma" => {factory: "figma", id: "figma", name: "Figma"},
  "github" => {factory: "github", id: "github", name: "GitHub"},
  "gitlab" => {factory: "gitlab", id: "gitlab", name: "GitLab"},
  "google" => {factory: "google", id: "google", name: "Google"},
  "huggingface" => {factory: "huggingface", id: "huggingface", name: "Hugging Face"},
  "kakao" => {factory: "kakao", id: "kakao", name: "Kakao"},
  "kick" => {factory: "kick", id: "kick", name: "Kick"},
  "line" => {factory: "line", id: "line", name: "LINE"},
  "linear" => {factory: "linear", id: "linear", name: "Linear"},
  "linkedin" => {factory: "linkedin", id: "linkedin", name: "LinkedIn"},
  "microsoft" => {factory: "microsoft", id: "microsoft", name: "Microsoft Entra ID", extra: "tenant_id: \"common\","},
  "naver" => {factory: "naver", id: "naver", name: "Naver"},
  "notion" => {factory: "notion", id: "notion", name: "Notion"},
  "paybin" => {factory: "paybin", id: "paybin", name: "Paybin"},
  "paypal" => {factory: "paypal", id: "paypal", name: "PayPal"},
  "polar" => {factory: "polar", id: "polar", name: "Polar"},
  "railway" => {factory: "railway", id: "railway", name: "Railway"},
  "reddit" => {factory: "reddit", id: "reddit", name: "Reddit"},
  "roblox" => {factory: "roblox", id: "roblox", name: "Roblox"},
  "salesforce" => {factory: "salesforce", id: "salesforce", name: "Salesforce"},
  "slack" => {factory: "slack", id: "slack", name: "Slack"},
  "spotify" => {factory: "spotify", id: "spotify", name: "Spotify"},
  "tiktok" => {factory: "tiktok", id: "tiktok", name: "TikTok"},
  "twitch" => {factory: "twitch", id: "twitch", name: "Twitch"},
  "twitter" => {factory: "twitter", id: "twitter", name: "Twitter / X"},
  "vercel" => {factory: "vercel", id: "vercel", name: "Vercel"},
  "vk" => {factory: "vk", id: "vk", name: "VK"},
  "wechat" => {factory: "wechat", id: "wechat", name: "WeChat"},
  "zoom" => {factory: "zoom", id: "zoom", name: "Zoom"}
}.freeze

PARTIAL_PLUGINS = {
  "admin" => "Admin plugin overlaps organization access control; some admin routes may not match upstream edge cases.",
  "anonymous" => "Anonymous linking on /email-otp/verify-email and SIWE verify paths is not fully parity-tested.",
  "captcha" => "Missing CAPTCHA secret key may surface as UNKNOWN_ERROR rather than MISSING_SECRET_KEY.",
  "last-login-method" => "Passkey and phone-number login method paths are not fully covered in parity tests.",
  "magic-link" => "Rack verify requests without a token return 400 validation instead of an errorCallback redirect.",
  "organization" => "Callable membership_limit is not enforced on add_member."
}.freeze

EXTERNAL_PLUGINS = {
  "api-key" => {
    gem: "better_auth-api-key",
    require: "better_auth/api_key",
    call: "BetterAuth::Plugins.api_key"
  },
  "sso" => {
    gem: "better_auth-sso",
    require: "better_auth/sso",
    call: "BetterAuth::Plugins.sso",
    note: "Add `gem \"better_auth-saml\"` when you need SAML identity providers."
  },
  "scim" => {
    gem: "better_auth-scim",
    require: "better_auth/scim",
    call: "BetterAuth::Plugins.scim"
  },
  "stripe" => {
    gem: "better_auth-stripe",
    require: "better_auth/stripe",
    call: "BetterAuth::Plugins.stripe(stripe_api_key: ENV.fetch(\"STRIPE_SECRET_KEY\"), stripe_webhook_secret: ENV.fetch(\"STRIPE_WEBHOOK_SECRET\"))"
  },
  "passkey" => {
    gem: "better_auth-passkey",
    require: "better_auth/passkey",
    call: "BetterAuth::Plugins.passkey(rp_id: \"localhost\", rp_name: \"My App\", origin: ENV.fetch(\"BETTER_AUTH_URL\"))"
  },
  "oauth-provider" => {
    gem: "better_auth-oauth-provider",
    require: "better_auth/oauth_provider",
    call: "BetterAuth::Plugins.oauth_provider(scopes: [\"openid\", \"profile\", \"email\"])"
  }
}.freeze

PLUGIN_META = {
  "2fa" => {title: "Two-Factor Authentication (2FA)", factory: "two_factor", desc: "TOTP, OTP, and backup codes for two-factor authentication.", opts: "issuer: \"My App\""},
  "admin" => {title: "Admin", factory: "admin", desc: "Admin APIs to manage users and sessions."},
  "anonymous" => {title: "Anonymous", factory: "anonymous", desc: "Temporary anonymous users that can link to a full account later."},
  "bearer" => {title: "Bearer", factory: "bearer", desc: "Bearer token authentication for API access."},
  "captcha" => {title: "CAPTCHA", factory: "captcha", desc: "Protect sign-in and sign-up with CAPTCHA providers.", opts: "provider: \"turnstile\", secret_key: ENV.fetch(\"TURNSTILE_SECRET_KEY\")"},
  "custom-session" => {title: "Custom Session", factory: "custom_session", desc: "Customize session payload returned from get-session."},
  "device-authorization" => {title: "Device Authorization", factory: "device_authorization", desc: "OAuth device authorization flow for TVs and CLI tools."},
  "dub" => {title: "Dub", factory: "dub", desc: "Dub referral and link tracking integration."},
  "email-otp" => {title: "Email OTP", factory: "email_otp", desc: "Email one-time passcodes for sign-in and verification.", opts: "send_verification_otp: ->(email, otp, _ctx) { UserMailer.otp(email, otp).deliver_now }"},
  "generic-oauth" => {title: "Generic OAuth", factory: "generic_oauth", desc: "Connect custom OAuth 2.0 / OIDC providers and presets (Auth0, Okta, Keycloak)."},
  "have-i-been-pwned" => {title: "Have I Been Pwned", factory: "have_i_been_pwned", desc: "Reject passwords found in known data breaches."},
  "jwt" => {title: "JWT", factory: "jwt", desc: "JWT session tokens and JWKS endpoints."},
  "last-login-method" => {title: "Last Login Method", factory: "last_login_method", desc: "Track and expose the user's last login method."},
  "magic-link" => {title: "Magic Link", factory: "magic_link", desc: "Passwordless email magic-link sign-in.", opts: "send_magic_link: ->(email, url, _token, _ctx) { UserMailer.magic_link(email, url).deliver_now }"},
  "multi-session" => {title: "Multi Session", factory: "multi_session", desc: "Support multiple concurrent sessions per user."},
  "oauth-proxy" => {title: "OAuth Proxy", factory: "oauth_proxy", desc: "Proxy OAuth requests through your server."},
  "oidc-provider" => {title: "OIDC Provider", factory: "oidc_provider", desc: "OpenID Connect provider endpoints (in-core)."},
  "one-tap" => {title: "One Tap", factory: "one_tap", desc: "Google One Tap server-side verification."},
  "one-time-token" => {title: "One-Time Token", factory: "one_time_token", desc: "Single-use tokens for secure actions."},
  "open-api" => {title: "Open API", factory: "open_api", desc: "OpenAPI schema generation for auth routes."},
  "organization" => {title: "Organization", factory: "organization", desc: "Multi-tenant organizations, members, roles, and invitations."},
  "phone-number" => {title: "Phone Number", factory: "phone_number", desc: "Phone number sign-in and verification."},
  "siwe" => {title: "Sign In With Ethereum", factory: "siwe", desc: "Ethereum wallet authentication (SIWE)."},
  "username" => {title: "Username", factory: "username", desc: "Username-based sign-in alongside email."},
  "api-key" => {title: "API Key", factory: "api_key", desc: "Issue and verify API keys for programmatic access."},
  "sso" => {title: "SSO", factory: "sso", desc: "Enterprise SSO with OIDC and SAML providers."},
  "scim" => {title: "SCIM", factory: "scim", desc: "SCIM 2.0 user provisioning for identity platforms."},
  "stripe" => {title: "Stripe", factory: "stripe", desc: "Stripe subscriptions and customer billing."},
  "passkey" => {title: "Passkey", factory: "passkey", desc: "WebAuthn passkey authentication."},
  "oauth-provider" => {title: "OAuth Provider", factory: "oauth_provider", desc: "Turn your app into an OAuth 2.0 authorization server."}
}.freeze

def write(path, content)
  File.write(path, content)
  puts "wrote #{path}"
end

def provider_mdx(slug, meta)
  env_prefix = slug.upcase.tr("-", "_")
  key = slug.tr("-", "_")
  extra = meta[:extra] ? "\n      #{meta[:extra]}" : ""

  <<~MDX
    ---
    title: #{meta[:name]}
    description: #{meta[:name]} OAuth provider setup for RubyAuth.
    ---

    ## Configure

    Add #{meta[:name]} to your RubyAuth configuration:

    ```ruby
    BetterAuth.auth(
      base_url: ENV.fetch("BETTER_AUTH_URL"),
      secret: ENV.fetch("BETTER_AUTH_SECRET"),
      social_providers: {
        #{key}: BetterAuth::SocialProviders.#{meta[:factory]}(
          client_id: ENV.fetch("#{env_prefix}_CLIENT_ID"),
          client_secret: ENV.fetch("#{env_prefix}_CLIENT_SECRET")#{",#{extra}" unless extra.empty?}
        )
      }
    )
    ```

    ## Callback URL

    Register this redirect URI in your #{meta[:name]} developer console:

    ```
    {BETTER_AUTH_URL}/api/auth/callback/#{meta[:id]}
    ```

    Example for local development: `http://localhost:3000/api/auth/callback/#{meta[:id]}`

    ## Environment variables

    | Variable | Description |
    |----------|-------------|
    | `#{env_prefix}_CLIENT_ID` | OAuth client ID |
    | `#{env_prefix}_CLIENT_SECRET` | OAuth client secret |
    | `BETTER_AUTH_URL` | Public base URL of your app |
    | `BETTER_AUTH_SECRET` | Auth signing secret |

    ## Sign in

    Redirect users or link to:

    ```
    GET /api/auth/sign-in/social?provider=#{meta[:id]}
    ```

    RubyAuth uses PKCE where required by the provider. There is no official browser client gem — use HTTP redirects or `fetch` from your frontend.

    ## Related

    - [OAuth concepts](/docs/concepts/oauth)
    - [Other social providers](/docs/authentication/other-social-providers)
  MDX
end

def email_password_mdx
  <<~MDX
    ---
    title: Email & Password
    description: Email and password authentication in RubyAuth.
    ---

    <RubyAuthDisclaimer />

    Enable built-in email/password authentication in your auth configuration.

    ## Configure

    ```ruby
    BetterAuth.auth(
      base_url: ENV.fetch("BETTER_AUTH_URL"),
      secret: ENV.fetch("BETTER_AUTH_SECRET"),
      email_and_password: {
        enabled: true,
        require_email_verification: false,
        min_password_length: 8
      }
    )
    ```

    Rails initializer:

    ```ruby
    BetterAuth::Rails.configure do |config|
      config.email_and_password do |email_and_password|
        email_and_password.enabled = true
      end
    end
    ```

    ## Routes

    | Method | Path | Purpose |
    |--------|------|---------|
    | `POST` | `/api/auth/sign-up/email` | Create account |
    | `POST` | `/api/auth/sign-in/email` | Sign in |
    | `POST` | `/api/auth/sign-out` | Sign out |
    | `POST` | `/api/auth/forget-password` | Request reset email |
    | `POST` | `/api/auth/reset-password` | Complete password reset |

    See [Basic usage](/docs/basic-usage) for curl examples and [Email](/docs/concepts/email) for verification and reset mailers.

    ## Related

    - [Email OTP plugin](/docs/plugins/email-otp)
    - [Have I Been Pwned](/docs/plugins/have-i-been-pwned)
  MDX
end

def other_social_mdx
  <<~MDX
    ---
    title: Other Social Providers
    description: Custom OAuth providers with Generic OAuth presets in RubyAuth.
    ---

    <RubyAuthDisclaimer />

    RubyAuth ships 34 built-in social providers under `BetterAuth::SocialProviders`. For providers not in that list, use the **Generic OAuth** plugin with presets or a custom configuration.

    ## Presets

    The generic OAuth plugin includes presets such as Auth0, Okta, and Keycloak:

    ```ruby
    BetterAuth.auth(
      plugins: [
        BetterAuth::Plugins.generic_oauth(
          config: [
            BetterAuth::Plugins::GenericOAuth.auth0(
              client_id: ENV.fetch("AUTH0_CLIENT_ID"),
              client_secret: ENV.fetch("AUTH0_CLIENT_SECRET"),
              domain: ENV.fetch("AUTH0_DOMAIN")
            )
          ]
        )
      ]
    )
    ```

    See [Generic OAuth plugin](/docs/plugins/generic-oauth) for all presets and custom issuer configuration.

    ## Custom provider

    ```ruby
    BetterAuth::Plugins.generic_oauth(
      config: [
        {
          provider_id: "custom",
          client_id: ENV.fetch("CUSTOM_CLIENT_ID"),
          client_secret: ENV.fetch("CUSTOM_CLIENT_SECRET"),
          discovery_url: "https://issuer.example/.well-known/openid-configuration"
        }
      ]
    )
    ```

    Callback URL pattern: `{BETTER_AUTH_URL}/api/auth/callback/{provider_id}`

    ## Related

    - [OAuth concepts](/docs/concepts/oauth)
    - [Plugins index](/docs/plugins)
  MDX
end

def plugin_mdx(slug, meta)
  partial = PARTIAL_PLUGINS[slug]
  external = EXTERNAL_PLUGINS[slug]
  factory = meta[:factory]
  opts = meta[:opts]
  call = if external
    external[:call]
  elsif opts
    "BetterAuth::Plugins.#{factory}(#{opts})"
  else
    "BetterAuth::Plugins.#{factory}"
  end

  gem_block = if external
    note = external[:note] ? "\n\n#{external[:note]}" : ""
    <<~GEM

      ```ruby title="Gemfile"
      gem "#{external[:gem]}"
      ```

      ```ruby
      require "#{external[:require]}"
      ```
      #{note}
    GEM
  else
    ""
  end

  under_dev = if partial
    <<~DEV

      <UnderDevelopment>
        #{partial}
      </UnderDevelopment>
    DEV
  else
    ""
  end

  <<~MDX
    ---
    title: #{meta[:title]}
    description: #{meta[:desc]}
    ---

    #{under_dev}#{gem_block}
    ## Installation

    Add the plugin to your auth configuration:

    ```ruby
    BetterAuth.auth(
      base_url: ENV.fetch("BETTER_AUTH_URL"),
      secret: ENV.fetch("BETTER_AUTH_SECRET"),
      database: :postgres,
      plugins: [
        #{call}
      ]
    )
    ```

    Regenerate migrations after enabling a plugin:

    ```bash
    bundle exec better-auth generate --cwd . --dialect postgres --output db/better_auth/schema.sql
    # Rails: bin/rails generate better_auth:migration && bin/rails db:migrate
    ```

    ## Usage

    Plugin routes are served under `/api/auth` on your mounted auth handler. Call the same endpoints over HTTP from your frontend, or use `auth.api` from Ruby code inside your app.

    See the plugin tests under `packages/better_auth/test/better_auth/plugins/` for request/response examples.

    ## Related

    - [Plugins concept](/docs/concepts/plugins)
    - [Plugins index](/docs/plugins)
  MDX
end

def plugins_index_mdx
  core = PLUGIN_META.keys.reject { |s| EXTERNAL_PLUGINS.key?(s) }
  external = EXTERNAL_PLUGINS.keys
  <<~MDX
    ---
    title: Plugins
    description: RubyAuth server plugins — core gem and external packages.
    ---

    <RubyAuthDisclaimer />

    Plugins extend RubyAuth with 2FA, organizations, OAuth presets, billing, and more. Enable plugins in the `plugins` array of your auth configuration.

    There is **no browser client plugin layer** in RubyAuth — frontends call HTTP routes under `/api/auth`.

    ## Core plugins (`better_auth` gem)

    #{core.map { |s| "- [#{PLUGIN_META[s][:title]}](/docs/plugins/#{s})" }.join("\n")}

    ## External gem plugins

    #{external.map { |s| "- [#{PLUGIN_META[s]&.dig(:title) || s.titleize}](/docs/plugins/#{s}) — `#{EXTERNAL_PLUGINS[s][:gem]}`" }.join("\n")}

    Partial parity with upstream Better Auth is marked **Under development** on individual plugin pages.

    ## Not documented in RubyAuth

    Upstream-only plugins removed from this docs site include MCP, agent-auth, i18n, test-utils, and third-party payment plugins (Autumn, Chargebee, Creem, Dodo Payments). Use [Stripe](/docs/plugins/stripe) for Ruby billing integration.

    ## Community

    See [Community plugins](/docs/plugins/community-plugins) for contributing adapter or plugin gems.

    ## Related

    - [Plugins concept](/docs/concepts/plugins)
    - [Installation](/docs/installation)
  MDX
end

def community_plugins_mdx
  <<~MDX
    ---
    title: Community Plugins
    description: Contributing Ruby plugin and adapter gems for RubyAuth.
    ---

    <RubyAuthDisclaimer />

    RubyAuth plugins live in the monorepo as gems (`better_auth-api-key`, `better_auth-sso`, `better_auth-stripe`, etc.) or in the core `better_auth` gem under `BetterAuth::Plugins`.

    There is no npm-style community plugin registry. To add functionality:

    1. Implement a plugin in a gem or in `packages/better_auth/lib/better_auth/plugins/`
    2. Add tests under `packages/better_auth/test/better_auth/plugins/`
    3. Document the gem in `docs-site/content/docs/plugins/`

    ## Official extension gems

    | Gem | Feature |
    |-----|---------|
    | `better_auth-api-key` | API keys |
    | `better_auth-passkey` | WebAuthn / passkeys |
    | `better_auth-sso` | Enterprise SSO (OIDC; add `better_auth-saml` for SAML) |
    | `better_auth-scim` | SCIM provisioning |
    | `better_auth-stripe` | Stripe subscriptions |
    | `better_auth-oauth-provider` | OAuth 2.0 provider mode |

    See [Plugins index](/docs/plugins) for setup guides.
  MDX
end

def api_key_pages
  {
    "index.mdx" => <<~MDX,
      ---
      title: API Key
      description: Issue and verify API keys with the better_auth-api-key gem.
      ---

      ```ruby title="Gemfile"
      gem "better_auth-api-key"
      ```

      ```ruby
      require "better_auth/api_key"

      BetterAuth.auth(
        plugins: [BetterAuth::Plugins.api_key]
      )
      ```

      Key routes include `POST /api/auth/api-key/create` and `POST /api/auth/api-key/verify`. Use `auth.api.create_api_key` and `auth.api.verify_api_key` from Ruby.

      See the [API Key plugin README](https://github.com/better-auth/better-auth-ruby/tree/main/packages/better_auth-api-key) in the monorepo for the full route table.
    MDX
    "reference.mdx" => <<~MDX,
      ---
      title: API Key Reference
      description: API key plugin routes and auth.api methods.
      ---

      Server routes are mounted under `/api/auth`. Common endpoints:

      | Method | Path |
      |--------|------|
      | `POST` | `/api-key/create` |
      | `POST` | `/api-key/verify` |
      | `GET` | `/api-key/list` |
      | `POST` | `/api-key/delete` |

      Call via `auth.api` with `body:`, `headers:`, and `query:` keyword arguments. See `packages/better_auth-api-key/README.md` for method names and options.
    MDX
    "advanced.mdx" => <<~MDX
      ---
      title: API Key Advanced
      description: Advanced API key configuration in RubyAuth.
      ---

      Configure rate limits, metadata, organization-owned keys, and multiple key configurations through `BetterAuth::Plugins.api_key(...)` options. Read `packages/better_auth-api-key/README.md` and `packages/better_auth-api-key/lib/better_auth/plugins/api_key.rb` for supported options.

      Regenerate schema after changing plugin options:

      ```bash
      bin/rails generate better_auth:migration
      ```
    MDX
  }
end

# Generate auth pages
PROVIDER_MAP.each do |slug, meta|
  write(File.join(AUTH_DIR, "#{slug}.mdx"), provider_mdx(slug, meta))
end
write(File.join(AUTH_DIR, "email-password.mdx"), email_password_mdx)
write(File.join(AUTH_DIR, "other-social-providers.mdx"), other_social_mdx)

# Generate plugin pages
PLUGIN_META.each do |slug, meta|
  write(File.join(PLUGINS_DIR, "#{slug}.mdx"), plugin_mdx(slug, meta))
end

write(File.join(PLUGINS_DIR, "index.mdx"), plugins_index_mdx)
write(File.join(PLUGINS_DIR, "community-plugins.mdx"), community_plugins_mdx)

api_key_pages.each do |name, content|
  write(File.join(PLUGINS_DIR, "api-key", name), content)
end

puts "done"
