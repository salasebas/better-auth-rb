# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    remove_method :sso if method_defined?(:sso) || private_method_defined?(:sso)
    singleton_class.remove_method(:sso) if singleton_class.method_defined?(:sso) || singleton_class.private_method_defined?(:sso)

    SSO_ERROR_CODES = {
      "PROVIDER_NOT_FOUND" => "No provider found",
      "INVALID_STATE" => "Invalid state",
      "SAML_RESPONSE_REPLAYED" => "SAML response has already been used",
      "SINGLE_LOGOUT_NOT_ENABLED" => "Single Logout is not enabled",
      "INVALID_LOGOUT_REQUEST" => "Invalid LogoutRequest",
      "INVALID_LOGOUT_RESPONSE" => "Invalid LogoutResponse",
      "LOGOUT_FAILED_AT_IDP" => "Logout failed at IdP",
      "IDP_SLO_NOT_SUPPORTED" => "IdP does not support Single Logout Service"
    }.freeze

    SSO_SAML_SIGNATURE_ALGORITHMS = {
      "rsa-sha1" => "http://www.w3.org/2000/09/xmldsig#rsa-sha1",
      "rsa-sha256" => "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256",
      "rsa-sha384" => "http://www.w3.org/2001/04/xmldsig-more#rsa-sha384",
      "rsa-sha512" => "http://www.w3.org/2001/04/xmldsig-more#rsa-sha512",
      "ecdsa-sha256" => "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256",
      "ecdsa-sha384" => "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha384",
      "ecdsa-sha512" => "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha512",
      "sha1" => "http://www.w3.org/2000/09/xmldsig#rsa-sha1",
      "sha256" => "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256",
      "sha384" => "http://www.w3.org/2001/04/xmldsig-more#rsa-sha384",
      "sha512" => "http://www.w3.org/2001/04/xmldsig-more#rsa-sha512"
    }.freeze

    SSO_SAML_DIGEST_ALGORITHMS = {
      "sha1" => "http://www.w3.org/2000/09/xmldsig#sha1",
      "sha256" => "http://www.w3.org/2001/04/xmlenc#sha256",
      "sha384" => "http://www.w3.org/2001/04/xmldsig-more#sha384",
      "sha512" => "http://www.w3.org/2001/04/xmlenc#sha512"
    }.freeze

    SSO_SAML_SECURE_SIGNATURE_ALGORITHMS = (SSO_SAML_SIGNATURE_ALGORITHMS.values - ["http://www.w3.org/2000/09/xmldsig#rsa-sha1"]).uniq.freeze
    SSO_SAML_SECURE_DIGEST_ALGORITHMS = (SSO_SAML_DIGEST_ALGORITHMS.values - ["http://www.w3.org/2000/09/xmldsig#sha1"]).uniq.freeze
    SSO_SAML_SECURE_KEY_ENCRYPTION_ALGORITHMS = %w[
      http://www.w3.org/2001/04/xmlenc#rsa-oaep-mgf1p
      http://www.w3.org/2009/xmlenc11#rsa-oaep
    ].freeze
    SSO_SAML_SECURE_DATA_ENCRYPTION_ALGORITHMS = %w[
      http://www.w3.org/2001/04/xmlenc#aes128-cbc
      http://www.w3.org/2001/04/xmlenc#aes192-cbc
      http://www.w3.org/2001/04/xmlenc#aes256-cbc
      http://www.w3.org/2009/xmlenc11#aes128-gcm
      http://www.w3.org/2009/xmlenc11#aes192-gcm
      http://www.w3.org/2009/xmlenc11#aes256-gcm
    ].freeze
    SSO_DEFAULT_MAX_SAML_RESPONSE_SIZE = 256 * 1024
    SSO_DEFAULT_MAX_SAML_METADATA_SIZE = 100 * 1024
    SSO_SAML_RELAY_STATE_KEY_PREFIX = "saml-relay-state:"
    SSO_SAML_AUTHN_REQUEST_KEY_PREFIX = "saml-authn-request:"
    SSO_DEFAULT_AUTHN_REQUEST_TTL_MS = 5 * 60 * 1000
    SSO_SAML_USED_ASSERTION_KEY_PREFIX = "saml-used-assertion:"
    SSO_DEFAULT_ASSERTION_TTL_MS = 15 * 60 * 1000
    SSO_DEFAULT_CLOCK_SKEW_MS = 5 * 60 * 1000
    SSO_SAML_SESSION_KEY_PREFIX = "saml-session:"
    SSO_SAML_SESSION_BY_ID_KEY_PREFIX = "saml-session-by-id:"
    SSO_SAML_LOGOUT_REQUEST_KEY_PREFIX = "saml-logout-request:"
    SSO_SAML_STATUS_SUCCESS = "urn:oasis:names:tc:SAML:2.0:status:Success"
    SSO_DEFAULT_LOGOUT_REQUEST_TTL_MS = 5 * 60 * 1000
    SSO_DEFAULT_OIDC_HTTP_TIMEOUT = 10
    SSO_DEFAULT_OIDC_HTTP_MAX_BODY_SIZE = 1024 * 1024
    SSO_OIDC_PKCE_VERIFIER_KEY_PREFIX = "oidc-pkce-verifier:"

    def sso(options = {})
      config = normalize_hash(options)
      if defined?(BetterAuth::SSO::SAML) && defined?(BetterAuth::SSO::SAMLHooks)
        config = BetterAuth::SSO::SAMLHooks.merge_options(BetterAuth::SSO::SAML.sso_options, config)
      end
      endpoints = BetterAuth::SSO::Routes::SSO.endpoints(config)
      Plugin.new(
        id: "sso",
        init: ->(_ctx) { {options: {advanced: {disable_origin_check: ["/sso/saml2/callback", "/sso/saml2/sp/acs", "/sso/saml2/sp/slo"]}}} },
        schema: BetterAuth::SSO::Routes::Schemas.plugin_schema(config),
        endpoints: endpoints,
        hooks: sso_hooks(config),
        error_codes: SSO_ERROR_CODES,
        options: config
      )
    end

    def sso_hooks(config = {})
      {
        before: [
          {
            matcher: ->(ctx) { ctx.path == "/sign-out" },
            handler: ->(ctx) { sso_before_sign_out(ctx, config) }
          }
        ],
        after: [
          {
            matcher: ->(ctx) { ctx.path.to_s.match?(%r{\A/callback/[^/]+\z}) },
            handler: ->(ctx) { sso_after_generic_callback(ctx, config) }
          }
        ]
      }
    end

    def sso_before_sign_out(ctx, config = {})
      return unless config.dig(:saml, :enable_single_logout)

      token_cookie = ctx.context.auth_cookies[:session_token]
      session_token = ctx.get_signed_cookie(token_cookie.name, ctx.context.secret)
      return if session_token.to_s.empty?

      lookup_key = "#{SSO_SAML_SESSION_BY_ID_KEY_PREFIX}#{session_token}"
      session_lookup = ctx.context.internal_adapter.find_verification_value(lookup_key)
      saml_session_key = session_lookup&.fetch("value", nil)
      ctx.context.internal_adapter.delete_verification_by_identifier(saml_session_key) if saml_session_key
      ctx.context.internal_adapter.delete_verification_by_identifier(lookup_key)
      nil
    rescue
      nil
    end

    def sso_after_generic_callback(ctx, config = {})
      new_session = ctx.context.new_session if ctx.context.respond_to?(:new_session)
      return unless new_session && new_session[:user]
      return unless defined?(BetterAuth::SSO::Linking::OrgAssignment)

      BetterAuth::SSO::Linking::OrgAssignment.assign_organization_by_domain(
        ctx,
        user: new_session.fetch(:user),
        provisioning_options: config[:organization_provisioning],
        domain_verification: config[:domain_verification]
      )
      nil
    end

    def sso_schema(config = {})
      BetterAuth::SSO::Routes::Schemas.plugin_schema(config)
    end
  end
end
