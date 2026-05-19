# frozen_string_literal: true

module BetterAuth
  module SSO
    module Routes
      module Schemas
        OIDC_MAPPING_KEYS = %i[id email email_verified name image extra_fields].freeze
        SAML_MAPPING_KEYS = %i[id email email_verified name first_name last_name extra_fields].freeze
        OIDC_CONFIG_KEYS = %i[
          client_id
          client_secret
          authorization_endpoint
          token_endpoint
          user_info_endpoint
          token_endpoint_authentication
          jwks_endpoint
          discovery_endpoint
          scopes
          pkce
          override_user_info
          mapping
        ].freeze
        SAML_CONFIG_KEYS = %i[
          entry_point
          cert
          callback_url
          audience
          idp_metadata
          sp_metadata
          want_assertions_signed
          authn_requests_signed
          want_logout_request_signed
          want_logout_response_signed
          signature_algorithm
          digest_algorithm
          identifier_format
          private_key
          decryption_pvk
          additional_params
          mapping
        ].freeze

        module_function

        def plugin_schema(config = {})
          normalized = BetterAuth::Plugins.normalize_hash(config || {})
          field_mappings = BetterAuth::Plugins.normalize_hash(normalized[:fields] || {})
          fields = {
            issuer: field("issuer", {type: "string", required: true}, field_mappings),
            oidcConfig: field("oidcConfig", {type: "string", required: false}, field_mappings),
            samlConfig: field("samlConfig", {type: "string", required: false}, field_mappings),
            userId: field("userId", {type: "string", required: true, references: {model: "user", field: "id"}}, field_mappings),
            providerId: field("providerId", {type: "string", required: true, unique: true}, field_mappings),
            domain: field("domain", {type: "string", required: true}, field_mappings),
            organizationId: field("organizationId", {type: "string", required: false}, field_mappings)
          }
          if normalized.dig(:domain_verification, :enabled)
            fields[:domainVerified] = field("domainVerified", {type: "boolean", required: false, default_value: false}, field_mappings)
          end
          {
            ssoProvider: {
              model_name: normalized[:model_name] || "sso_providers",
              fields: fields
            }
          }
        end

        def oidc_config_key?(key)
          OIDC_CONFIG_KEYS.include?(BetterAuth::Plugins.normalize_key(key))
        end

        def saml_config_key?(key)
          SAML_CONFIG_KEYS.include?(BetterAuth::Plugins.normalize_key(key))
        end

        def field(logical_name, attributes, mappings)
          mapping = mappings[BetterAuth::Plugins.normalize_key(logical_name)]
          mapping ? attributes.merge(field_name: mapping) : attributes
        end
      end
    end
  end
end
