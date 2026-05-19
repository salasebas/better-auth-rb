# frozen_string_literal: true

require_relative "../../../test_helper"

class BetterAuthSSORoutesSchemasTest < Minitest::Test
  SCHEMAS = BetterAuth::SSO::Routes::Schemas

  def test_oidc_config_keys_match_upstream_schema_fields
    assert_equal(
      %i[
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
      ],
      SCHEMAS::OIDC_CONFIG_KEYS
    )
  end

  def test_saml_config_keys_include_upstream_schema_fields
    upstream_keys = %i[
      entry_point
      cert
      callback_url
      audience
      idp_metadata
      sp_metadata
      want_assertions_signed
      authn_requests_signed
      signature_algorithm
      digest_algorithm
      identifier_format
      private_key
      decryption_pvk
      additional_params
      mapping
    ]

    upstream_keys.each do |key|
      assert_includes SCHEMAS::SAML_CONFIG_KEYS, key
    end
  end

  def test_mapping_keys_match_upstream_oidc_and_saml_shapes
    assert_equal(
      %i[id email email_verified name image extra_fields],
      SCHEMAS::OIDC_MAPPING_KEYS
    )
    assert_equal(
      %i[id email email_verified name first_name last_name extra_fields],
      SCHEMAS::SAML_MAPPING_KEYS
    )
  end

  def test_config_key_helpers_accept_camel_case_and_snake_case_names
    assert SCHEMAS.oidc_config_key?("clientId")
    assert SCHEMAS.oidc_config_key?(:client_id)
    assert SCHEMAS.oidc_config_key?("tokenEndpointAuthentication")
    assert SCHEMAS.oidc_config_key?(:token_endpoint_authentication)
    assert SCHEMAS.oidc_config_key?("overrideUserInfo")
    assert SCHEMAS.oidc_config_key?(:override_user_info)

    assert SCHEMAS.saml_config_key?("entryPoint")
    assert SCHEMAS.saml_config_key?(:entry_point)
    assert SCHEMAS.saml_config_key?("idpMetadata")
    assert SCHEMAS.saml_config_key?(:idp_metadata)
    assert SCHEMAS.saml_config_key?("authnRequestsSigned")
    assert SCHEMAS.saml_config_key?(:authn_requests_signed)
  end

  def test_config_key_helpers_reject_unknown_fields
    refute SCHEMAS.oidc_config_key?("issuer")
    refute SCHEMAS.oidc_config_key?("emailVerified")
    refute SCHEMAS.saml_config_key?("issuer")
    refute SCHEMAS.saml_config_key?("firstName")
  end

  def test_plugin_schema_matches_public_sso_provider_storage_shape
    schema = SCHEMAS.plugin_schema(model_name: "customSSOProviders")
    provider = schema.fetch(:ssoProvider)
    fields = provider.fetch(:fields)

    assert_equal "customSSOProviders", provider.fetch(:model_name)
    assert_equal({type: "string", required: true}, fields.fetch(:issuer))
    assert_equal({type: "string", required: false}, fields.fetch(:oidcConfig))
    assert_equal({type: "string", required: false}, fields.fetch(:samlConfig))
    assert_equal({type: "string", required: true, references: {model: "user", field: "id"}}, fields.fetch(:userId))
    assert_equal({type: "string", required: true, unique: true}, fields.fetch(:providerId))
    assert_equal({type: "string", required: true}, fields.fetch(:domain))
    assert_equal({type: "string", required: false}, fields.fetch(:organizationId))
    refute fields.key?(:domainVerified)
  end

  def test_plugin_schema_applies_upstream_field_mappings
    schema = SCHEMAS.plugin_schema(
      fields: {
        issuer: "sso_issuer",
        oidcConfig: "oidc_config",
        samlConfig: "saml_config",
        userId: "owner_id",
        providerId: "provider_id",
        organizationId: "org_id",
        domain: "email_domain",
        domainVerified: "domain_verified"
      },
      domainVerification: {enabled: true}
    )
    fields = schema.fetch(:ssoProvider).fetch(:fields)

    assert_equal "sso_issuer", fields.fetch(:issuer).fetch(:field_name)
    assert_equal "oidc_config", fields.fetch(:oidcConfig).fetch(:field_name)
    assert_equal "saml_config", fields.fetch(:samlConfig).fetch(:field_name)
    assert_equal "owner_id", fields.fetch(:userId).fetch(:field_name)
    assert_equal "provider_id", fields.fetch(:providerId).fetch(:field_name)
    assert_equal "org_id", fields.fetch(:organizationId).fetch(:field_name)
    assert_equal "email_domain", fields.fetch(:domain).fetch(:field_name)
    assert_equal "domain_verified", fields.fetch(:domainVerified).fetch(:field_name)
  end

  def test_plugin_schema_includes_domain_verified_when_domain_verification_is_enabled
    schema = SCHEMAS.plugin_schema(domainVerification: {enabled: true})
    fields = schema.fetch(:ssoProvider).fetch(:fields)

    assert_equal "sso_providers", schema.fetch(:ssoProvider).fetch(:model_name)
    assert_equal({type: "boolean", required: false, default_value: false}, fields.fetch(:domainVerified))
  end
end
