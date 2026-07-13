# frozen_string_literal: true

require "json"
require_relative "../../test_helper"

class BetterAuthSSOProvidersTest < Minitest::Test
  SECRET = "providers-secret-with-enough-entropy-123"
  TEST_CERT = "MIIDXTCCAkWgAwIBAgIJAJC1HiIAZAiUMA0Gcm9markup"

  def test_get_provider_sanitizes_serialized_oidc_config_from_database
    auth = build_auth
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_oidc_provider(auth, user.fetch("id"), "oidc-provider", "client-id-12345")

    provider = auth.api.get_sso_provider(headers: {"cookie" => cookie}, query: {providerId: "oidc-provider"})

    assert_equal "oidc-provider", provider.fetch("providerId")
    assert_equal "oidc", provider.fetch("type")
    assert_equal "****2345", provider.fetch("oidcConfig").fetch("clientIdLastFour")
    assert_equal "https://idp.example.com/.well-known", provider.fetch("oidcConfig").fetch("discoveryEndpoint")
    refute JSON.generate(provider).include?("super-secret-value")
    refute JSON.generate(provider).include?("clientSecret")
  end

  def test_get_provider_sanitizes_serialized_saml_config_from_database
    auth = build_auth
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, user.fetch("id"), "saml-provider")

    provider = auth.api.get_sso_provider(headers: {"cookie" => cookie}, query: {providerId: "saml-provider"})

    assert_equal "saml", provider.fetch("type")
    assert_equal "https://idp.example.com/sso", provider.fetch("samlConfig").fetch("entryPoint")
    assert_equal "my-audience", provider.fetch("samlConfig").fetch("audience")
    assert provider.fetch("samlConfig").fetch("certificate")
    refute JSON.generate(provider).include?(TEST_CERT)
  end

  def test_update_provider_merges_serialized_oidc_config_from_database
    auth = build_auth
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_oidc_provider(auth, user.fetch("id"), "oidc-provider", "client123")

    updated = auth.api.update_sso_provider(
      headers: {"cookie" => cookie},
      body: {
        providerId: "oidc-provider",
        oidcConfig: {
          scopes: ["openid", "email", "profile", "custom"],
          pkce: false
        }
      }
    )

    assert_equal ["openid", "email", "profile", "custom"], updated.fetch("oidcConfig").fetch("scopes")
    assert_equal false, updated.fetch("oidcConfig").fetch("pkce")
    assert_equal "****t123", updated.fetch("oidcConfig").fetch("clientIdLastFour")
  end

  def test_update_provider_merges_serialized_saml_config_from_database
    auth = build_auth
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, user.fetch("id"), "saml-provider")

    updated = auth.api.update_sso_provider(
      headers: {"cookie" => cookie},
      body: {
        providerId: "saml-provider",
        samlConfig: {
          audience: "new-audience",
          wantAssertionsSigned: false
        }
      }
    )

    assert_equal "new-audience", updated.fetch("samlConfig").fetch("audience")
    assert_equal false, updated.fetch("samlConfig").fetch("wantAssertionsSigned")
    assert_equal "https://idp.example.com/sso", updated.fetch("samlConfig").fetch("entryPoint")
  end

  def test_list_providers_handles_comma_separated_org_admin_roles
    auth = build_auth(plugins: [BetterAuth::Plugins.sso, BetterAuth::Plugins.organization])
    owner_cookie = sign_up_cookie(auth, "owner@example.com")
    org = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Test Org", slug: "test-org"})
    owner = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, owner.fetch("id"), "org-provider", organization_id: org.fetch("id"))

    multi_cookie = sign_up_cookie(auth, "multi@example.com")
    multi_user = user_by_email(auth, "multi@example.com")
    auth.context.adapter.create(
      model: "member",
      data: {
        id: "multi-member",
        userId: multi_user.fetch("id"),
        organizationId: org.fetch("id"),
        role: "admin,member"
      }
    )

    response = auth.api.list_sso_providers(headers: {"cookie" => multi_cookie})

    assert_equal ["org-provider"], response.fetch(:providers).map { |provider| provider.fetch("providerId") }
  end

  def test_register_provider_requires_organization_admin_or_owner
    auth = build_auth(plugins: [BetterAuth::Plugins.sso, BetterAuth::Plugins.organization])
    owner_cookie = sign_up_cookie(auth, "owner@example.com")
    org = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Test Org", slug: "test-org"})
    member_cookie = sign_up_cookie(auth, "member@example.com")
    member = user_by_email(auth, "member@example.com")
    create_member(auth, member.fetch("id"), org.fetch("id"), "member")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.register_sso_provider(
        headers: {"cookie" => member_cookie},
        body: {
          providerId: "member-provider",
          issuer: "https://idp.example.com",
          domain: "example.com",
          organizationId: org.fetch("id"),
          oidcConfig: {clientId: "client", skipDiscovery: true, authorizationEndpoint: "https://idp.example.com/authorize", tokenEndpoint: "https://idp.example.com/token"}
        }
      )
    end

    assert_equal 403, error.status_code
    assert_equal "You must be an organization owner or admin to register SSO providers", error.message
  end

  def test_list_providers_requires_authentication
    auth = build_auth

    error = assert_raises(BetterAuth::APIError) do
      auth.api.list_sso_providers
    end

    assert_equal 401, error.status_code
  end

  def test_list_providers_returns_empty_list_when_none_exist
    auth = build_auth
    cookie = sign_up_cookie(auth)

    response = auth.api.list_sso_providers(headers: {"cookie" => cookie})

    assert_equal [], response.fetch(:providers)
  end

  def test_list_providers_returns_only_owned_providers_without_org_plugin
    auth = build_auth
    owner_cookie = sign_up_cookie(auth, "owner@example.com")
    owner = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, owner.fetch("id"), "my-provider")
    create_serialized_oidc_provider(auth, "different-user-id", "other-provider", "client123")

    response = auth.api.list_sso_providers(headers: {"cookie" => owner_cookie})

    assert_equal ["my-provider"], response.fetch(:providers).map { |provider| provider.fetch("providerId") }
  end

  def test_list_providers_returns_org_provider_for_org_owner
    auth = build_auth(plugins: [BetterAuth::Plugins.sso, BetterAuth::Plugins.organization])
    owner_cookie = sign_up_cookie(auth, "owner@example.com")
    org = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Test Org", slug: "test-org"})
    owner = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, owner.fetch("id"), "org-provider", organization_id: org.fetch("id"))

    response = auth.api.list_sso_providers(headers: {"cookie" => owner_cookie})

    assert_equal ["org-provider"], response.fetch(:providers).map { |provider| provider.fetch("providerId") }
  end

  def test_list_providers_returns_org_provider_for_org_admin
    auth = build_auth(plugins: [BetterAuth::Plugins.sso, BetterAuth::Plugins.organization])
    owner_cookie = sign_up_cookie(auth, "owner@example.com")
    org = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Test Org", slug: "test-org"})
    owner = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, owner.fetch("id"), "org-provider", organization_id: org.fetch("id"))

    admin_cookie = sign_up_cookie(auth, "admin@example.com")
    admin = user_by_email(auth, "admin@example.com")
    create_member(auth, admin.fetch("id"), org.fetch("id"), "admin")

    response = auth.api.list_sso_providers(headers: {"cookie" => admin_cookie})

    assert_equal ["org-provider"], response.fetch(:providers).map { |provider| provider.fetch("providerId") }
  end

  def test_list_providers_hides_org_provider_from_non_admin_member
    auth = build_auth(plugins: [BetterAuth::Plugins.sso, BetterAuth::Plugins.organization])
    owner_cookie = sign_up_cookie(auth, "owner@example.com")
    org = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Test Org", slug: "test-org"})
    owner = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, owner.fetch("id"), "org-provider", organization_id: org.fetch("id"))

    member_cookie = sign_up_cookie(auth, "member@example.com")
    member = user_by_email(auth, "member@example.com")
    create_member(auth, member.fetch("id"), org.fetch("id"), "member")

    response = auth.api.list_sso_providers(headers: {"cookie" => member_cookie})

    assert_equal [], response.fetch(:providers)
  end

  def test_list_providers_allows_owned_org_id_provider_when_org_plugin_disabled
    auth = build_auth
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, user.fetch("id"), "owned-org-id-provider", organization_id: "external-org-id")

    response = auth.api.list_sso_providers(headers: {"cookie" => cookie})

    assert_equal ["owned-org-id-provider"], response.fetch(:providers).map { |provider| provider.fetch("providerId") }
  end

  def test_list_providers_requires_org_admin_for_owned_org_id_provider_when_org_plugin_enabled
    auth = build_auth(plugins: [BetterAuth::Plugins.sso, BetterAuth::Plugins.organization])
    owner_cookie = sign_up_cookie(auth, "owner@example.com")
    org = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Test Org", slug: "test-org"})
    owner = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, owner.fetch("id"), "owned-org-provider", organization_id: org.fetch("id"))

    owner_response = auth.api.list_sso_providers(headers: {"cookie" => owner_cookie})
    assert_equal ["owned-org-provider"], owner_response.fetch(:providers).map { |provider| provider.fetch("providerId") }

    other_cookie = sign_up_cookie(auth, "other@example.com")
    other_response = auth.api.list_sso_providers(headers: {"cookie" => other_cookie})
    assert_equal [], other_response.fetch(:providers)
  end

  def test_get_provider_requires_authentication
    auth = build_auth

    error = assert_raises(BetterAuth::APIError) do
      auth.api.get_sso_provider(query: {providerId: "test"})
    end

    assert_equal 401, error.status_code
  end

  def test_get_provider_returns_not_found_for_missing_provider
    auth = build_auth
    cookie = sign_up_cookie(auth)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.get_sso_provider(headers: {"cookie" => cookie}, query: {providerId: "missing"})
    end

    assert_equal 404, error.status_code
  end

  def test_get_provider_rejects_unowned_provider
    auth = build_auth
    sign_up_cookie(auth, "owner@example.com")
    owner = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, owner.fetch("id"), "owned-provider")
    other_cookie = sign_up_cookie(auth, "other@example.com")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.get_sso_provider(headers: {"cookie" => other_cookie}, query: {providerId: "owned-provider"})
    end

    assert_equal 403, error.status_code
  end

  def test_get_provider_requires_org_admin_when_org_plugin_enabled
    auth = build_auth(plugins: [BetterAuth::Plugins.sso, BetterAuth::Plugins.organization])
    owner_cookie = sign_up_cookie(auth, "owner@example.com")
    org = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Test Org", slug: "test-org"})
    owner = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, owner.fetch("id"), "org-provider", organization_id: org.fetch("id"))

    owner_response = auth.api.get_sso_provider(headers: {"cookie" => owner_cookie}, query: {providerId: "org-provider"})
    assert_equal "org-provider", owner_response.fetch("providerId")

    other_cookie = sign_up_cookie(auth, "other@example.com")
    error = assert_raises(BetterAuth::APIError) do
      auth.api.get_sso_provider(headers: {"cookie" => other_cookie}, query: {providerId: "org-provider"})
    end

    assert_equal 403, error.status_code
  end

  def test_get_provider_allows_owned_org_id_provider_when_org_plugin_disabled
    auth = build_auth
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, user.fetch("id"), "owned-org-id-provider", organization_id: "external-org-id")

    provider = auth.api.get_sso_provider(headers: {"cookie" => cookie}, query: {providerId: "owned-org-id-provider"})

    assert_equal "owned-org-id-provider", provider.fetch("providerId")
  end

  def test_oidc_sanitization_masks_short_client_id_with_asterisks
    auth = build_auth
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_oidc_provider(auth, user.fetch("id"), "short-client", "abc")

    provider = auth.api.get_sso_provider(headers: {"cookie" => cookie}, query: {providerId: "short-client"})

    assert_equal "****", provider.fetch("oidcConfig").fetch("clientIdLastFour")
  end

  def test_saml_sanitization_handles_certificate_parse_errors
    auth = build_auth
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, user.fetch("id"), "bad-cert-provider", cert: "invalid-cert-data")

    provider = auth.api.get_sso_provider(headers: {"cookie" => cookie}, query: {providerId: "bad-cert-provider"})

    assert_equal "Failed to parse certificate", provider.fetch("samlConfig").fetch("certificate").fetch(:error)
  end

  def test_update_provider_requires_authentication
    auth = build_auth

    error = assert_raises(BetterAuth::APIError) do
      auth.api.update_sso_provider(body: {providerId: "test", domain: "new.example.com"})
    end

    assert_equal 401, error.status_code
  end

  def test_update_provider_returns_not_found_for_missing_provider
    auth = build_auth
    cookie = sign_up_cookie(auth)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.update_sso_provider(headers: {"cookie" => cookie}, body: {providerId: "missing", domain: "new.example.com"})
    end

    assert_equal 404, error.status_code
  end

  def test_update_provider_rejects_unowned_provider
    auth = build_auth
    sign_up_cookie(auth, "owner@example.com")
    owner = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, owner.fetch("id"), "owned-provider")
    other_cookie = sign_up_cookie(auth, "other@example.com")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.update_sso_provider(headers: {"cookie" => other_cookie}, body: {providerId: "owned-provider", domain: "new.example.com"})
    end

    assert_equal 403, error.status_code
  end

  def test_update_provider_resets_domain_verified_when_domain_changes
    auth = build_auth(domain_verification: {enabled: true})
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, user.fetch("id"), "saml-provider", domain_verified: true)

    updated = auth.api.update_sso_provider(headers: {"cookie" => cookie}, body: {providerId: "saml-provider", domain: "new-domain.com"})

    assert_equal "new-domain.com", updated.fetch("domain")
    assert_equal false, updated.fetch("domainVerified")
  end

  def test_update_provider_updates_issuer
    auth = build_auth
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, user.fetch("id"), "saml-provider")

    updated = auth.api.update_sso_provider(headers: {"cookie" => cookie}, body: {providerId: "saml-provider", issuer: "https://new-issuer.example.com"})

    assert_equal "https://new-issuer.example.com", updated.fetch("issuer")
  end

  def test_update_provider_rejects_invalid_issuer_url
    auth = build_auth
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, user.fetch("id"), "saml-provider")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.update_sso_provider(headers: {"cookie" => cookie}, body: {providerId: "saml-provider", issuer: "invalid-url"})
    end

    assert_equal 400, error.status_code
  end

  def test_update_provider_rejects_saml_metadata_that_exceeds_configured_limit
    auth = build_auth(saml: {maxMetadataSize: 16})
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, user.fetch("id"), "saml-provider")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.update_sso_provider(
        headers: {"cookie" => cookie},
        body: {
          providerId: "saml-provider",
          samlConfig: {idpMetadata: {metadata: "<EntityDescriptor>too-large</EntityDescriptor>"}}
        }
      )
    end

    assert_equal 400, error.status_code
    assert_includes error.message, "IdP metadata exceeds maximum allowed size"
  end

  def test_update_provider_rejects_deprecated_saml_algorithm_when_configured
    auth = build_auth(saml: {algorithms: {onDeprecated: "reject"}})
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, user.fetch("id"), "saml-provider")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.update_sso_provider(
        headers: {"cookie" => cookie},
        body: {providerId: "saml-provider", samlConfig: {signatureAlgorithm: "rsa-sha1"}}
      )
    end

    assert_equal 400, error.status_code
    assert_includes error.message, "deprecated signature algorithm"
  end

  def test_update_provider_merges_resolved_issuer_into_protocol_configs
    auth = build_auth
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, user.fetch("id"), "saml-provider")
    create_serialized_oidc_provider(auth, user.fetch("id"), "oidc-provider", "client123")

    auth.api.update_sso_provider(
      headers: {"cookie" => cookie},
      body: {
        providerId: "saml-provider",
        issuer: "https://new-saml-issuer.example.com",
        samlConfig: {callbackUrl: "/new-dashboard"}
      }
    )
    saml_provider = auth.context.adapter.find_one(model: "ssoProvider", where: [{field: "providerId", value: "saml-provider"}])
    saml_config = BetterAuth::Plugins.sso_provider_config_hash(saml_provider.fetch("samlConfig"))
    assert_equal "https://new-saml-issuer.example.com", saml_config.fetch(:issuer)

    auth.api.update_sso_provider(
      headers: {"cookie" => cookie},
      body: {
        providerId: "oidc-provider",
        issuer: "https://new-oidc-issuer.example.com",
        oidcConfig: {clientId: "client456"}
      }
    )
    oidc_provider = auth.context.adapter.find_one(model: "ssoProvider", where: [{field: "providerId", value: "oidc-provider"}])
    oidc_config = BetterAuth::Plugins.sso_provider_config_hash(oidc_provider.fetch("oidcConfig"))
    assert_equal "https://new-oidc-issuer.example.com", oidc_config.fetch(:issuer)
  end

  def test_update_provider_rejects_empty_update
    auth = build_auth
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, user.fetch("id"), "saml-provider")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.update_sso_provider(headers: {"cookie" => cookie}, body: {providerId: "saml-provider"})
    end

    assert_equal 400, error.status_code
    assert_equal "No fields provided for update", error.message
  end

  def test_update_provider_allows_org_admin_and_rejects_org_member
    auth = build_auth(plugins: [BetterAuth::Plugins.sso, BetterAuth::Plugins.organization])
    owner_cookie = sign_up_cookie(auth, "owner@example.com")
    org = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Test Org", slug: "test-org"})
    owner = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, owner.fetch("id"), "org-provider", organization_id: org.fetch("id"))

    admin_cookie = sign_up_cookie(auth, "admin@example.com")
    admin = user_by_email(auth, "admin@example.com")
    create_member(auth, admin.fetch("id"), org.fetch("id"), "admin")
    updated = auth.api.update_sso_provider(headers: {"cookie" => admin_cookie}, body: {providerId: "org-provider", domain: "admin-updated.com"})
    assert_equal "admin-updated.com", updated.fetch("domain")

    member_cookie = sign_up_cookie(auth, "member@example.com")
    member = user_by_email(auth, "member@example.com")
    create_member(auth, member.fetch("id"), org.fetch("id"), "member")
    error = assert_raises(BetterAuth::APIError) do
      auth.api.update_sso_provider(headers: {"cookie" => member_cookie}, body: {providerId: "org-provider", domain: "member-updated.com"})
    end
    assert_equal 403, error.status_code
  end

  def test_update_provider_rejects_config_type_mismatch
    auth = build_auth
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_oidc_provider(auth, user.fetch("id"), "oidc-provider", "client123")
    create_serialized_saml_provider(auth, user.fetch("id"), "saml-provider")

    saml_error = assert_raises(BetterAuth::APIError) do
      auth.api.update_sso_provider(headers: {"cookie" => cookie}, body: {providerId: "oidc-provider", samlConfig: {entryPoint: "https://idp.example.com/sso"}})
    end
    assert_equal 400, saml_error.status_code

    oidc_error = assert_raises(BetterAuth::APIError) do
      auth.api.update_sso_provider(headers: {"cookie" => cookie}, body: {providerId: "saml-provider", oidcConfig: {clientId: "new-client"}})
    end
    assert_equal 400, oidc_error.status_code
  end

  def test_delete_provider_requires_authentication
    auth = build_auth

    error = assert_raises(BetterAuth::APIError) do
      auth.api.delete_sso_provider(body: {providerId: "test"})
    end

    assert_equal 401, error.status_code
  end

  def test_delete_provider_returns_not_found_for_missing_provider
    auth = build_auth
    cookie = sign_up_cookie(auth)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.delete_sso_provider(headers: {"cookie" => cookie}, body: {providerId: "missing"})
    end

    assert_equal 404, error.status_code
  end

  def test_delete_provider_rejects_unowned_provider
    auth = build_auth
    sign_up_cookie(auth, "owner@example.com")
    owner = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, owner.fetch("id"), "owned-provider")
    other_cookie = sign_up_cookie(auth, "other@example.com")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.delete_sso_provider(headers: {"cookie" => other_cookie}, body: {providerId: "owned-provider"})
    end

    assert_equal 403, error.status_code
  end

  def test_delete_provider_transactionally_deletes_linked_accounts_but_preserves_user_and_other_identities
    auth = build_auth
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, user.fetch("id"), "saml-provider")
    auth.context.internal_adapter.create_account(userId: user.fetch("id"), providerId: "saml-provider", accountId: "saml-account-id")
    auth.context.internal_adapter.create_account(userId: user.fetch("id"), providerId: "sso:saml-provider", accountId: "prefixed-saml-account-id")
    auth.context.internal_adapter.create_account(userId: user.fetch("id"), providerId: "other-provider", accountId: "other-account-id")

    response = auth.api.delete_sso_provider(headers: {"cookie" => cookie}, body: {providerId: "saml-provider"})

    assert_equal({success: true}, response)
    accounts = auth.context.adapter.find_many(model: "account", where: [{field: "userId", value: user.fetch("id")}])
    assert_equal ["credential", "other-provider"], accounts.map { |account| account.fetch("providerId") }.sort
    assert auth.context.internal_adapter.find_user_by_id(user.fetch("id"))

    error = assert_raises(BetterAuth::APIError) do
      auth.api.get_sso_provider(headers: {"cookie" => cookie}, query: {providerId: "saml-provider"})
    end
    assert_equal 404, error.status_code
  end

  def test_update_provider_blocks_identity_changes_with_links_but_allows_secret_rotation
    auth = build_auth
    cookie = sign_up_cookie(auth)
    user = user_by_email(auth, "owner@example.com")
    create_serialized_oidc_provider(auth, user.fetch("id"), "oidc-provider", "client123")
    auth.context.internal_adapter.create_account(userId: user.fetch("id"), providerId: "sso:oidc-provider", accountId: "oidc-subject")

    conflict = assert_raises(BetterAuth::APIError) do
      auth.api.update_sso_provider(
        headers: {"cookie" => cookie},
        body: {providerId: "oidc-provider", oidcConfig: {clientId: "new-client-id"}}
      )
    end
    assert_equal 409, conflict.status_code

    auth.api.update_sso_provider(
      headers: {"cookie" => cookie},
      body: {providerId: "oidc-provider", oidcConfig: {clientSecret: "rotated-secret"}}
    )
    stored = auth.context.adapter.find_one(model: "ssoProvider", where: [{field: "providerId", value: "oidc-provider"}])
    assert_equal "rotated-secret", BetterAuth::Plugins.sso_provider_config_hash(stored.fetch("oidcConfig")).fetch(:client_secret)
  end

  def test_delete_provider_allows_org_admin_and_rejects_org_member
    auth = build_auth(plugins: [BetterAuth::Plugins.sso, BetterAuth::Plugins.organization])
    owner_cookie = sign_up_cookie(auth, "owner@example.com")
    org = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Test Org", slug: "test-org"})
    owner = user_by_email(auth, "owner@example.com")
    create_serialized_saml_provider(auth, owner.fetch("id"), "org-provider", organization_id: org.fetch("id"))

    member_cookie = sign_up_cookie(auth, "member@example.com")
    member = user_by_email(auth, "member@example.com")
    create_member(auth, member.fetch("id"), org.fetch("id"), "member")
    member_error = assert_raises(BetterAuth::APIError) do
      auth.api.delete_sso_provider(headers: {"cookie" => member_cookie}, body: {providerId: "org-provider"})
    end
    assert_equal 403, member_error.status_code

    admin_cookie = sign_up_cookie(auth, "admin@example.com")
    admin = user_by_email(auth, "admin@example.com")
    create_member(auth, admin.fetch("id"), org.fetch("id"), "admin")
    response = auth.api.delete_sso_provider(headers: {"cookie" => admin_cookie}, body: {providerId: "org-provider"})
    assert_equal({success: true}, response)
  end

  private

  def build_auth(plugin_options = nil, plugins: nil, **kwargs)
    plugin_options = (plugin_options || {}).merge(kwargs)
    BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: :memory,
      email_and_password: {enabled: true},
      plugins: plugins || [BetterAuth::Plugins.sso(plugin_options)]
    )
  end

  def sign_up_cookie(auth, email = "owner@example.com")
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: email, password: "password123", name: email.split("@").first},
      as_response: true
    )
    headers.fetch("set-cookie").to_s.lines.map { |line| line.split(";").first }.join("; ")
  end

  def user_by_email(auth, email)
    auth.context.internal_adapter.find_user_by_email(email).fetch(:user)
  end

  def create_serialized_oidc_provider(auth, user_id, provider_id, client_id, organization_id: nil)
    auth.context.adapter.create(
      model: "ssoProvider",
      data: {
        id: "oidc-#{provider_id}",
        providerId: provider_id,
        issuer: "https://idp.example.com",
        domain: "example.com",
        userId: user_id,
        organizationId: organization_id,
        oidcConfig: JSON.generate(
          clientId: client_id,
          clientSecret: "super-secret-value",
          discoveryEndpoint: "https://idp.example.com/.well-known",
          pkce: true
        )
      }
    )
  end

  def create_serialized_saml_provider(auth, user_id, provider_id, organization_id: nil, domain_verified: nil, cert: TEST_CERT)
    auth.context.adapter.create(
      model: "ssoProvider",
      data: {
        id: "saml-#{provider_id}",
        providerId: provider_id,
        issuer: "https://idp.example.com",
        domain: "example.com",
        userId: user_id,
        organizationId: organization_id,
        domainVerified: domain_verified,
        samlConfig: JSON.generate(
          entryPoint: "https://idp.example.com/sso",
          cert: cert,
          callbackUrl: "http://localhost:3000/api/sso/callback",
          audience: "my-audience",
          wantAssertionsSigned: true,
          spMetadata: {}
        )
      }
    )
  end

  def create_member(auth, user_id, organization_id, role)
    auth.context.adapter.create(
      model: "member",
      data: {
        id: "member-#{user_id}-#{role}",
        userId: user_id,
        organizationId: organization_id,
        role: role
      }
    )
  end
end
