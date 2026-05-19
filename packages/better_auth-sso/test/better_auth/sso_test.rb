# frozen_string_literal: true

require "json"
require "rack/mock"
require_relative "../test_helper"

class BetterAuthPluginsSSOTest < Minitest::Test
  SECRET = "phase-twelve-secret-with-enough-entropy-123"

  def test_visible_endpoints_have_complete_open_api_metadata
    plugin = BetterAuth::Plugins.sso
    missing = plugin.endpoints.filter_map do |key, endpoint|
      next unless endpoint.path
      next if endpoint.metadata[:hide] || endpoint.metadata[:SERVER_ONLY] || endpoint.metadata[:server_only]

      "#{plugin.id}.#{key}" unless rich_openapi?(endpoint)
    end

    assert_empty missing
  end

  def test_registers_sso_schema_and_provider_crud_routes
    auth = build_auth
    cookie = sign_up_cookie(auth)

    provider = auth.api.register_sso_provider(
      headers: {"cookie" => cookie},
      body: {
        providerId: "acme",
        issuer: "https://idp.acme.test",
        domain: "acme.test",
        oidcConfig: {
          clientId: "client-id",
          clientSecret: "client-secret",
          skipDiscovery: true,
          authorizationEndpoint: "https://idp.acme.test/authorize",
          tokenEndpoint: "https://idp.acme.test/token",
          userInfoEndpoint: "https://idp.acme.test/userinfo"
        }
      }
    )

    assert_equal "acme", provider.fetch("providerId")
    assert_equal "https://idp.acme.test", provider.fetch("issuer")
    assert_equal "acme.test", provider.fetch("domain")
    refute provider.key?("clientSecret")
    refute provider.key?("domainVerified")

    listed = auth.api.list_sso_providers(headers: {"cookie" => cookie})
    assert_equal ["acme"], listed.fetch(:providers).map { |item| item.fetch("providerId") }

    fetched = auth.api.get_sso_provider(headers: {"cookie" => cookie}, params: {providerId: "acme"})
    assert_equal "acme", fetched.fetch("providerId")
    assert_includes fetched.fetch("spMetadataUrl"), "/sso/saml2/sp/metadata?providerId=acme"

    updated = auth.api.update_sso_provider(
      headers: {"cookie" => cookie},
      params: {providerId: "acme"},
      body: {domain: "new.acme.test"}
    )
    assert_equal "new.acme.test", updated.fetch("domain")
    refute updated.key?("domainVerified")

    deleted = auth.api.delete_sso_provider(headers: {"cookie" => cookie}, params: {providerId: "acme"})
    assert_equal({success: true}, deleted)
    assert_empty auth.api.list_sso_providers(headers: {"cookie" => cookie}).fetch(:providers)
  end

  def test_update_sso_provider_rejects_invalid_issuer_url
    auth = build_auth
    cookie = sign_up_cookie(auth)
    auth.api.register_sso_provider(
      headers: {"cookie" => cookie},
      body: {
        providerId: "acme",
        issuer: "https://idp.acme.test",
        domain: "acme.test",
        oidcConfig: {
          clientId: "client-id",
          clientSecret: "client-secret",
          skipDiscovery: true,
          authorizationEndpoint: "https://idp.acme.test/authorize",
          tokenEndpoint: "https://idp.acme.test/token"
        }
      }
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.update_sso_provider(
        headers: {"cookie" => cookie},
        body: {providerId: "acme", issuer: "not-a-url"}
      )
    end

    assert_equal 400, error.status_code
    assert_equal "Invalid issuer. Must be a valid URL", error.message
  end

  def test_domain_verification_endpoints_are_registered_only_when_enabled
    disabled = build_auth
    refute_respond_to disabled.api, :request_domain_verification
    refute_respond_to disabled.api, :verify_domain

    enabled = build_auth(domain_verification: {enabled: true, dns_txt_resolver: ->(_hostname) { [] }})
    assert_respond_to enabled.api, :request_domain_verification
    assert_respond_to enabled.api, :verify_domain
  end

  def test_sign_in_sso_selects_provider_by_email_domain_and_redirects
    auth = build_auth
    cookie = sign_up_cookie(auth)
    auth.api.register_sso_provider(
      headers: {"cookie" => cookie},
      body: {
        providerId: "acme",
        issuer: "https://idp.acme.test",
        domain: "acme.test",
        oidcConfig: {
          clientId: "client-id",
          clientSecret: "client-secret",
          skipDiscovery: true,
          authorizationEndpoint: "https://idp.acme.test/authorize",
          tokenEndpoint: "https://idp.acme.test/token",
          userInfoEndpoint: "https://idp.acme.test/userinfo"
        }
      }
    )

    result = auth.api.sign_in_sso(body: {email: "someone@acme.test", callbackURL: "/dashboard"})
    uri = URI.parse(result[:url])
    params = Rack::Utils.parse_query(uri.query)

    assert_equal "https://idp.acme.test", "#{uri.scheme}://#{uri.host}"
    assert_equal "/authorize", uri.path
    assert_equal "client-id", params.fetch("client_id")
    assert_equal "http://localhost:3000/api/auth/sso/callback/acme", params.fetch("redirect_uri")
    assert params.fetch("state")
  end

  def test_email_domain_matching_follows_upstream_utility_rules
    assert BetterAuth::Plugins.sso_email_domain_matches?("Ada@Sub.Acme.Test", "acme.test")
    assert BetterAuth::Plugins.sso_email_domain_matches?("ada@team.example.com", "other.test, example.com")
    assert BetterAuth::Plugins.sso_email_domain_matches?("team.example.com", " example.com ")
    refute BetterAuth::Plugins.sso_email_domain_matches?("ada@notexample.com", "example.com")
    refute BetterAuth::Plugins.sso_email_domain_matches?("adaexample.com", "example.com")
    refute BetterAuth::Plugins.sso_email_domain_matches?("", "example.com")
    refute BetterAuth::Plugins.sso_email_domain_matches?("ada@example.com", "")
  end

  def test_sso_hostname_from_domain_follows_upstream_utility_rules
    assert_equal "github.com", BetterAuth::Plugins.sso_hostname_from_domain("github.com")
    assert_equal "github.com", BetterAuth::Plugins.sso_hostname_from_domain("https://github.com")
    assert_equal "github.com", BetterAuth::Plugins.sso_hostname_from_domain("https://github.com:8081")
    assert_equal "auth.github.com", BetterAuth::Plugins.sso_hostname_from_domain("auth.github.com")
    assert_equal "github.com", BetterAuth::Plugins.sso_hostname_from_domain("https://github.com/path/to/resource")
    assert_nil BetterAuth::Plugins.sso_hostname_from_domain("")
  end

  def test_domain_verification_lifecycle
    verification_requests = []
    token = nil
    auth = build_auth(
      domain_verification: {
        enabled: true,
        request: ->(provider:, token:, **_data) { verification_requests << [provider.fetch("providerId"), token] },
        dns_txt_resolver: ->(hostname) {
          assert_equal "_better-auth-token-acme.acme.test", hostname
          [["_better-auth-token-acme=#{token}"]]
        }
      }
    )
    cookie = sign_up_cookie(auth)
    registered = auth.api.register_sso_provider(
      headers: {"cookie" => cookie},
      body: {
        providerId: "acme",
        issuer: "https://idp.acme.test",
        domain: "acme.test",
        oidcConfig: {clientId: "client-id", clientSecret: "client-secret", skipDiscovery: true, authorizationEndpoint: "https://idp.acme.test/authorize"}
      }
    )
    token = registered.fetch(:domainVerificationToken)

    requested = auth.api.request_domain_verification(headers: {"cookie" => cookie}, body: {providerId: "acme"})
    assert_empty verification_requests
    assert_equal token, requested.fetch(:domainVerificationToken)
    assert_equal 24, token.length

    verified = auth.api.verify_domain(headers: {"cookie" => cookie}, body: {providerId: "acme"}, return_status: true)
    assert_equal 204, verified.fetch(:status)
    provider = auth.api.get_sso_provider(headers: {"cookie" => cookie}, params: {providerId: "acme"})
    assert_equal true, provider.fetch("domainVerified")
  end

  def test_provider_access_is_limited_to_owner_or_org_admin
    auth = build_auth(plugins: [BetterAuth::Plugins.organization, BetterAuth::Plugins.sso])
    owner_cookie = sign_up_cookie(auth, "owner@example.com")
    other_cookie = sign_up_cookie(auth, "other@example.com")
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "SSO Org", slug: "sso-org"})

    auth.api.register_sso_provider(
      headers: {"cookie" => owner_cookie},
      body: {
        providerId: "owned",
        issuer: "https://idp.owned.test",
        domain: "owned.test",
        oidcConfig: {clientId: "owned-client", skipDiscovery: true, authorizationEndpoint: "https://idp.owned.test/authorize"}
      }
    )
    auth.api.register_sso_provider(
      headers: {"cookie" => owner_cookie},
      body: {
        providerId: "org",
        issuer: "https://idp.org.test",
        domain: "org.test",
        organizationId: organization.fetch("id"),
        oidcConfig: {clientId: "org-client", skipDiscovery: true, authorizationEndpoint: "https://idp.org.test/authorize"}
      }
    )

    owner_list = auth.api.list_sso_providers(headers: {"cookie" => owner_cookie}).fetch(:providers).map { |provider| provider.fetch("providerId") }
    assert_equal ["org", "owned"], owner_list.sort
    assert_empty auth.api.list_sso_providers(headers: {"cookie" => other_cookie}).fetch(:providers)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.get_sso_provider(headers: {"cookie" => other_cookie}, params: {providerId: "owned"})
    end
    assert_equal 403, error.status_code
  end

  def test_provider_sanitization_masks_oidc_client_and_hides_saml_certificate
    auth = build_auth
    cookie = sign_up_cookie(auth)

    oidc = auth.api.register_sso_provider(
      headers: {"cookie" => cookie},
      body: {
        providerId: "oidc",
        issuer: "https://idp.oidc.test",
        domain: "oidc.test",
        oidcConfig: {
          clientId: "client-id-1234",
          clientSecret: "client-secret",
          skipDiscovery: true,
          authorizationEndpoint: "https://idp.oidc.test/authorize",
          tokenEndpoint: "https://idp.oidc.test/token"
        }
      }
    )
    assert_equal "oidc", oidc.fetch("type")
    assert_equal "****1234", oidc.fetch("oidcConfig").fetch("clientIdLastFour")
    refute oidc.fetch("oidcConfig").key?("clientId")
    refute oidc.fetch("oidcConfig").key?("clientSecret")

    saml = auth.api.register_sso_provider(
      headers: {"cookie" => cookie},
      body: {
        providerId: "saml",
        issuer: "https://idp.saml.test",
        domain: "saml.test",
        samlConfig: {entryPoint: "https://idp.saml.test/sso", cert: "not-a-cert", audience: "better-auth-ruby"}
      }
    )
    assert_equal "saml", saml.fetch("type")
    refute saml.fetch("samlConfig").key?("cert")
    assert_equal "Failed to parse certificate", saml.fetch("samlConfig").fetch("certificate").fetch(:error)
  end

  def test_upstream_provider_routes_and_registration_limits
    auth = build_auth(providers_limit: 2)
    cookie = sign_up_cookie(auth)

    provider = auth.api.register_sso_provider(
      headers: {"cookie" => cookie},
      body: {
        providerId: "acme",
        issuer: "https://idp.acme.test",
        domain: "acme.test",
        oidcConfig: {
          clientId: "client-id",
          clientSecret: "client-secret",
          skipDiscovery: true,
          authorizationEndpoint: "https://idp.acme.test/authorize",
          tokenEndpoint: "https://idp.acme.test/token",
          jwksEndpoint: "https://idp.acme.test/jwks"
        }
      }
    )
    assert_equal "http://localhost:3000/api/auth/sso/callback/acme", provider.fetch(:redirectURI)

    duplicate = assert_raises(BetterAuth::APIError) do
      auth.api.register_sso_provider(
        headers: {"cookie" => cookie},
        body: {
          providerId: "acme",
          issuer: "https://idp.acme.test",
          domain: "acme.test",
          oidcConfig: {clientId: "client-id", skipDiscovery: true}
        }
      )
    end
    assert_equal 422, duplicate.status_code
    assert_equal "SSO provider with this providerId already exists", duplicate.message

    fetched = auth.api.get_sso_provider(headers: {"cookie" => cookie}, query: {providerId: "acme"})
    assert_equal "acme", fetched.fetch("providerId")

    updated = auth.api.update_sso_provider(
      headers: {"cookie" => cookie},
      body: {
        providerId: "acme",
        oidcConfig: {scopes: ["openid", "email", "profile", "offline_access"]}
      }
    )
    assert_equal ["openid", "email", "profile", "offline_access"], updated.fetch("oidcConfig").fetch("scopes")

    deleted = auth.api.delete_sso_provider(headers: {"cookie" => cookie}, body: {providerId: "acme"})
    assert_equal({success: true}, deleted)

    limited_auth = build_auth(providers_limit: 1)
    limited_cookie = sign_up_cookie(limited_auth)
    limited_auth.api.register_sso_provider(
      headers: {"cookie" => limited_cookie},
      body: {
        providerId: "first",
        issuer: "https://idp.first.test",
        domain: "first.test",
        oidcConfig: {clientId: "client-id", skipDiscovery: true}
      }
    )
    limit = assert_raises(BetterAuth::APIError) do
      limited_auth.api.register_sso_provider(
        headers: {"cookie" => limited_cookie},
        body: {
          providerId: "second",
          issuer: "https://idp.second.test",
          domain: "second.test",
          oidcConfig: {clientId: "client-id", skipDiscovery: true}
        }
      )
    end
    assert_equal 403, limit.status_code
    assert_equal "You have reached the maximum number of SSO providers", limit.message
  end

  def test_domain_verification_matches_upstream_storage_and_statuses
    resolver_enabled = false
    expected_token = nil
    auth = build_auth(
      domain_verification: {
        enabled: true,
        dns_txt_resolver: ->(hostname) {
          next [] unless resolver_enabled

          assert_equal "_better-auth-token-acme.acme.test", hostname
          [["_better-auth-token-acme=#{expected_token}"]]
        }
      }
    )
    cookie = sign_up_cookie(auth)
    auth.api.register_sso_provider(
      headers: {"cookie" => cookie},
      body: {
        providerId: "acme",
        issuer: "https://idp.acme.test",
        domain: "acme.test",
        oidcConfig: {clientId: "client-id", skipDiscovery: true}
      }
    )

    first = auth.api.request_domain_verification(headers: {"cookie" => cookie}, body: {providerId: "acme"}, return_status: true)
    assert_equal 201, first.fetch(:status)
    token = first.fetch(:response).fetch(:domainVerificationToken)
    assert_equal 24, token.length

    second = auth.api.request_domain_verification(headers: {"cookie" => cookie}, body: {providerId: "acme"})
    assert_equal token, second.fetch(:domainVerificationToken)

    identifier = "_better-auth-token-acme"
    verification = auth.context.internal_adapter.find_verification_value(identifier)
    assert_equal token, verification.fetch("value")

    no_dns = assert_raises(BetterAuth::APIError) do
      auth.api.verify_domain(headers: {"cookie" => cookie}, body: {providerId: "acme"})
    end
    assert_equal 502, no_dns.status_code

    resolver_enabled = true
    expected_token = token
    verified = auth.api.verify_domain(
      headers: {"cookie" => cookie},
      body: {providerId: "acme"},
      return_status: true
    )
    assert_equal 204, verified.fetch(:status)
    assert_nil verified.fetch(:response)

    conflict = assert_raises(BetterAuth::APIError) do
      auth.api.request_domain_verification(headers: {"cookie" => cookie}, body: {providerId: "acme"})
    end
    assert_equal 409, conflict.status_code
  end

  def test_saml_sign_out_hook_deletes_saml_session_verification_records
    auth = build_auth(saml: {enableSingleLogout: true})
    cookie = sign_up_cookie(auth, "saml-signout@example.com")
    token = cookie[/better-auth\.session_token=([^;]+)/, 1].to_s.rpartition(".").first
    saml_session_key = "#{BetterAuth::Plugins::SSO_SAML_SESSION_KEY_PREFIX}saml:name-id"
    lookup_key = "#{BetterAuth::Plugins::SSO_SAML_SESSION_BY_ID_KEY_PREFIX}#{token}"

    auth.context.internal_adapter.create_verification_value(
      identifier: saml_session_key,
      value: JSON.generate({sessionToken: token}),
      expiresAt: Time.now + 300
    )
    auth.context.internal_adapter.create_verification_value(
      identifier: lookup_key,
      value: saml_session_key,
      expiresAt: Time.now + 300
    )

    auth.api.sign_out(headers: {"cookie" => cookie})

    assert_nil auth.context.internal_adapter.find_verification_value(lookup_key)
    assert_nil auth.context.internal_adapter.find_verification_value(saml_session_key)
  end

  def test_sso_after_hook_assigns_organization_by_verified_domain_after_generic_oauth_callback
    callback_plugin = BetterAuth::Plugin.new(
      id: "callback-test",
      endpoints: {
        callback_test: BetterAuth::Endpoint.new(path: "/callback/test", method: "GET") do |ctx|
          user = ctx.context.internal_adapter.create_user(email: "member@example.com", name: "Domain Member", emailVerified: true)
          session = ctx.context.internal_adapter.create_session(user.fetch("id"))
          BetterAuth::Cookies.set_session_cookie(ctx, {session: session, user: user})
          ctx.json({ok: true})
        end
      }
    )
    auth = build_auth(
      domain_verification: {enabled: true},
      plugins: [BetterAuth::Plugins.organization, BetterAuth::Plugins.sso(domain_verification: {enabled: true}), callback_plugin]
    )
    owner_cookie = sign_up_cookie(auth, "owner@example.com")
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Domain Org", slug: "domain-org"})
    owner = auth.context.internal_adapter.find_user_by_email("owner@example.com").fetch(:user)
    auth.context.adapter.create(
      model: "ssoProvider",
      data: {
        providerId: "domain-provider",
        issuer: "https://idp.example.com",
        domain: "example.com",
        userId: owner.fetch("id"),
        organizationId: organization.fetch("id"),
        domainVerified: true
      }
    )

    auth.api.callback_test
    member = auth.context.internal_adapter.find_user_by_email("member@example.com").fetch(:user)
    membership = auth.context.adapter.find_one(
      model: "member",
      where: [{field: "organizationId", value: organization.fetch("id")}, {field: "userId", value: member.fetch("id")}]
    )

    assert membership
    assert_equal "member", membership.fetch("role")
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
    cookie_header(headers.fetch("set-cookie"))
  end

  def cookie_header(set_cookie)
    set_cookie.to_s.lines.map { |line| line.split(";").first }.join("; ")
  end

  def rich_openapi?(endpoint)
    openapi = endpoint.metadata[:openapi]
    return false unless openapi.is_a?(Hash)
    return false if openapi[:operationId].to_s.empty?
    return false if endpoint.methods.any? { |method| openapi[:description].to_s == "#{method} #{endpoint.path}" }
    return false unless openapi[:responses].is_a?(Hash) && openapi[:responses].any?
    return false if endpoint.methods.any? { |method| %w[POST PUT PATCH].include?(method) } && !meaningful_schema?(openapi.dig(:requestBody, :content, "application/json", :schema))
    return false if endpoint.path.to_s.include?(":") && !Array(openapi[:parameters]).any? { |parameter| parameter[:in] == "path" }

    true
  end

  def meaningful_schema?(schema)
    schema.is_a?(Hash) && (schema[:additionalProperties] || schema[:$ref] || schema[:items] || schema[:properties]&.any?)
  end
end
