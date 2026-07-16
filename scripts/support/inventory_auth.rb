# frozen_string_literal: true

require "better_auth"

module InventoryAuth
  module_function

  def build_inventory_auth
    require_plugin_gems!

    delivery = ->(*args) { args }
    stripe_client = Class.new do
      def self.const_missing(_name) = nil
    end

    BetterAuth.auth(
      secret: "test-secret-that-is-long-enough-for-validation",
      base_url: "http://localhost:3000/api/auth",
      database: :memory,
      email_and_password: {enabled: true},
      plugins: [
        BetterAuth::Plugins.additional_fields(user: {nickname: {type: "string", required: false}}),
        BetterAuth::Plugins.username,
        BetterAuth::Plugins.anonymous,
        BetterAuth::Plugins.magic_link(send_magic_link: delivery),
        BetterAuth::Plugins.email_otp(send_verification_otp: delivery),
        BetterAuth::Plugins.phone_number(send_otp: delivery),
        BetterAuth::Plugins.one_time_token,
        BetterAuth::Plugins.custom_session(->(session, _ctx) { session }),
        BetterAuth::Plugins.last_login_method,
        BetterAuth::Plugins.multi_session,
        BetterAuth::Plugins.bearer,
        BetterAuth::Plugins.jwt,
        BetterAuth::Plugins.open_api,
        BetterAuth::Plugins.generic_oauth(
          config: [{
            provider_id: "example-oauth",
            client_id: "example-client",
            client_secret: "example-secret",
            authorization_url: "https://example.com/oauth/authorize",
            token_url: "https://example.com/oauth/token",
            scopes: ["profile", "email"]
          }]
        ),
        BetterAuth::Plugins.oauth_popup,
        BetterAuth::Plugins.one_tap(
          client_id: "example-google-client",
          verify_id_token: ->(_token, _ctx, **_opts) { {sub: "1", email: "one-tap@example.test", email_verified: true, name: "One Tap"} }
        ),
        BetterAuth::Plugins.siwe(get_nonce: -> { "nonce" }, verify_message: ->(*_args) { true }),
        BetterAuth::Plugins.dub,
        BetterAuth::Plugins.oauth_proxy,
        BetterAuth::Plugins.expo,
        BetterAuth::Plugins.organization(teams: {enabled: true}, dynamic_access_control: {enabled: true}),
        BetterAuth::Plugins.admin,
        BetterAuth::Plugins.api_key,
        BetterAuth::Plugins.passkey,
        BetterAuth::Plugins.oauth_provider(login_page: "/", consent_page: "/oauth2/consent"),
        BetterAuth::Plugins.scim,
        BetterAuth::Plugins.sso,
        BetterAuth::Plugins.stripe(
          stripe_client: stripe_client,
          subscription: {enabled: true, plans: [{name: "example", price_id: "price_example"}]}
        ),
        BetterAuth::Plugins.device_authorization,
        BetterAuth::Plugins.two_factor(issuer: "inventory", otp_options: {send_otp: delivery}),
        BetterAuth::Plugins.captcha(secret_key: "secret", provider: "google-recaptcha", endpoints: ["/sign-up/email"], verifier: ->(_params) { {success: true} }),
        BetterAuth::Plugins.have_i_been_pwned(range_lookup: ->(_prefix) { "" }),
        BetterAuth::Plugins.i18n(translations: {"en" => {"INVALID_EMAIL_OR_PASSWORD" => "Invalid"}})
      ]
    )
  end

  def require_plugin_gems!
    require "better_auth/api_key"
    require "better_auth/oauth_provider"
    require "better_auth/passkey"
    require "better_auth/scim"
    require "better_auth/sso"
    require "better_auth/stripe"
  end
end
