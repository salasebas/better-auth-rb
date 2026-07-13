# frozen_string_literal: true

require "json"
require_relative "../../test_helper"

class BetterAuthSSODomainVerificationTest < Minitest::Test
  SECRET = "domain-verification-secret-with-enough-entropy"

  def test_register_sso_provider_creates_domain_verification_token_when_enabled
    auth = build_auth
    cookie = sign_up_cookie(auth)

    provider = register_sso_provider(auth, cookie)

    assert_equal false, provider.fetch("domainVerified")
    assert_equal 24, provider.fetch(:domainVerificationToken).length
    verification = auth.context.internal_adapter.find_verification_value("_better-auth-token-saml-provider-1")
    assert_equal provider.fetch(:domainVerificationToken), verification.fetch("value")
  end

  def test_request_domain_verification_returns_existing_active_registration_token
    auth = build_auth
    cookie = sign_up_cookie(auth)
    provider = register_sso_provider(auth, cookie)

    response = auth.api.request_domain_verification(
      headers: {"cookie" => cookie},
      body: {providerId: provider.fetch("providerId")},
      return_status: true
    )

    assert_equal 201, response.fetch(:status)
    assert_equal provider.fetch(:domainVerificationToken), response.fetch(:response).fetch(:domainVerificationToken)
  end

  def test_request_domain_verification_returns_unauthorized_when_session_is_missing
    auth = build_auth

    error = assert_raises(BetterAuth::APIError) do
      auth.api.request_domain_verification(body: {providerId: "saml-provider-1"})
    end

    assert_equal 401, error.status_code
  end

  def test_request_domain_verification_returns_not_found_when_provider_is_missing
    auth = build_auth
    cookie = sign_up_cookie(auth)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.request_domain_verification(headers: {"cookie" => cookie}, body: {providerId: "unknown"})
    end

    assert_equal 404, error.status_code
    assert_equal "PROVIDER_NOT_FOUND", error.code
    assert_equal "Provider not found", error.message
  end

  def test_request_domain_verification_rejects_non_owner
    auth = build_auth
    owner_cookie = sign_up_cookie(auth, "owner@example.com")
    provider = register_sso_provider(auth, owner_cookie)
    other_cookie = sign_up_cookie(auth, "other@example.com")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.request_domain_verification(
        headers: {"cookie" => other_cookie},
        body: {providerId: provider.fetch("providerId")}
      )
    end

    assert_equal 403, error.status_code
    assert_equal "INSUFFICIENT_ACCESS", error.code
  end

  def test_request_domain_verification_rejects_user_outside_provider_organization
    auth = build_auth(plugins: [BetterAuth::Plugins.sso(domain_verification: {enabled: true}), BetterAuth::Plugins.organization])
    owner_cookie = sign_up_cookie(auth, "owner@example.com")
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Org A", slug: "org-a"})
    provider = register_sso_provider(auth, owner_cookie, organization_id: organization.fetch("id"))
    other_cookie = sign_up_cookie(auth, "other@example.com")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.request_domain_verification(
        headers: {"cookie" => other_cookie},
        body: {providerId: provider.fetch("providerId")}
      )
    end

    assert_equal 403, error.status_code
    assert_equal "INSUFFICIENT_ACCESS", error.code
  end

  def test_request_domain_verification_returns_new_token_after_active_token_expires
    auth = build_auth
    cookie = sign_up_cookie(auth)
    provider = register_sso_provider(auth, cookie)
    identifier = "_better-auth-token-saml-provider-1"
    old_token = provider.fetch(:domainVerificationToken)

    auth.context.internal_adapter.delete_verification_by_identifier(identifier)
    auth.context.internal_adapter.create_verification_value(identifier: identifier, value: old_token, expiresAt: Time.now - 1)

    response = auth.api.request_domain_verification(headers: {"cookie" => cookie}, body: {providerId: provider.fetch("providerId")})

    refute_equal old_token, response.fetch(:domainVerificationToken)
    assert_equal 24, response.fetch(:domainVerificationToken).length
  end

  def test_request_domain_verification_fails_when_domain_is_already_verified
    auth = build_auth(
      domain_verification: {
        enabled: true,
        dns_txt_resolver: ->(_hostname) { [["_better-auth-token-saml-provider-1=#{@domain_verification_token}"]] }
      }
    )
    cookie = sign_up_cookie(auth)
    provider = register_sso_provider(auth, cookie)
    @domain_verification_token = provider.fetch(:domainVerificationToken)
    auth.api.verify_domain(headers: {"cookie" => cookie}, body: {providerId: provider.fetch("providerId")})

    error = assert_raises(BetterAuth::APIError) do
      auth.api.request_domain_verification(headers: {"cookie" => cookie}, body: {providerId: provider.fetch("providerId")})
    end

    assert_equal 409, error.status_code
    assert_equal "DOMAIN_VERIFIED", error.code
  end

  def test_verify_domain_returns_unauthorized_when_session_is_missing
    auth = build_auth

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_domain(body: {providerId: "saml-provider-1"})
    end

    assert_equal 401, error.status_code
  end

  def test_verify_domain_returns_not_found_when_provider_is_missing
    auth = build_auth
    cookie = sign_up_cookie(auth)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_domain(headers: {"cookie" => cookie}, body: {providerId: "unknown"})
    end

    assert_equal 404, error.status_code
    assert_equal "PROVIDER_NOT_FOUND", error.code
    assert_equal "Provider not found", error.message
  end

  def test_verify_domain_returns_not_found_when_pending_verification_is_missing
    auth = build_auth
    cookie = sign_up_cookie(auth)
    provider = register_sso_provider(auth, cookie)
    auth.context.internal_adapter.delete_verification_by_identifier("_better-auth-token-saml-provider-1")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_domain(headers: {"cookie" => cookie}, body: {providerId: provider.fetch("providerId")})
    end

    assert_equal 404, error.status_code
    assert_equal "NO_PENDING_VERIFICATION", error.code
  end

  def test_verify_domain_rejects_non_owner_for_organization_provider
    auth = build_auth(plugins: [BetterAuth::Plugins.sso(domain_verification: {enabled: true}), BetterAuth::Plugins.organization])
    owner_cookie = sign_up_cookie(auth, "owner@example.com")
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Org A", slug: "org-a"})
    provider = register_sso_provider(auth, owner_cookie, organization_id: organization.fetch("id"))
    other_cookie = sign_up_cookie(auth, "other@example.com")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_domain(headers: {"cookie" => other_cookie}, body: {providerId: provider.fetch("providerId")})
    end

    assert_equal 403, error.status_code
    assert_equal "INSUFFICIENT_ACCESS", error.code
  end

  def test_verify_domain_rejects_non_owner
    auth = build_auth
    owner_cookie = sign_up_cookie(auth, "owner@example.com")
    provider = register_sso_provider(auth, owner_cookie)
    other_cookie = sign_up_cookie(auth, "other@example.com")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_domain(headers: {"cookie" => other_cookie}, body: {providerId: provider.fetch("providerId")})
    end

    assert_equal 403, error.status_code
    assert_equal "INSUFFICIENT_ACCESS", error.code
  end

  def test_verify_domain_uses_custom_token_prefix_from_camel_case_config
    seen_hostname = nil
    auth = build_auth(
      domainVerification: {
        enabled: true,
        tokenPrefix: "auth-prefix",
        dnsTxtResolver: ->(hostname) {
          seen_hostname = hostname
          [["_auth-prefix-saml-provider-1=#{@domain_verification_token}"]]
        }
      }
    )
    cookie = sign_up_cookie(auth)
    provider = register_sso_provider(auth, cookie, domain: "http://hello.com:8081")
    @domain_verification_token = provider.fetch(:domainVerificationToken)

    response = auth.api.verify_domain(headers: {"cookie" => cookie}, body: {providerId: provider.fetch("providerId")}, return_status: true)

    assert_equal 204, response.fetch(:status)
    assert_equal "_auth-prefix-saml-provider-1.hello.com", seen_hostname
  end

  def test_verify_domain_supports_bare_domain
    seen_hostname = nil
    auth = build_auth(
      domain_verification: {
        enabled: true,
        dns_txt_resolver: ->(hostname) {
          seen_hostname = hostname
          [["_better-auth-token-bare-domain-provider=#{@domain_verification_token}"]]
        }
      }
    )
    cookie = sign_up_cookie(auth)
    provider = register_sso_provider(auth, cookie, provider_id: "bare-domain-provider", domain: "hello.com")
    @domain_verification_token = provider.fetch(:domainVerificationToken)

    response = auth.api.verify_domain(headers: {"cookie" => cookie}, body: {providerId: provider.fetch("providerId")}, return_status: true)

    assert_equal 204, response.fetch(:status)
    assert_equal "_better-auth-token-bare-domain-provider.hello.com", seen_hostname
  end

  def test_verify_domain_requires_proof_for_every_listed_domain_and_accepts_raw_token
    seen = []
    auth = build_auth(
      domain_verification: {
        enabled: true,
        dns_txt_resolver: ->(hostname) {
          seen << hostname
          hostname.end_with?("first.example.com") ? [[@domain_verification_token]] : [["_better-auth-token-multi-domain=#{@domain_verification_token}"]]
        }
      }
    )
    cookie = sign_up_cookie(auth)
    provider = register_sso_provider(auth, cookie, provider_id: "multi-domain", domain: "first.example.com, second.example.com")
    @domain_verification_token = provider.fetch(:domainVerificationToken)

    response = auth.api.verify_domain(headers: {"cookie" => cookie}, body: {providerId: provider.fetch("providerId")}, return_status: true)

    assert_equal 204, response.fetch(:status)
    assert_equal ["_better-auth-token-multi-domain.first.example.com", "_better-auth-token-multi-domain.second.example.com"], seen
  end

  def test_org_admin_can_verify_provider_owned_by_another_org_admin
    auth = build_auth(plugins: [BetterAuth::Plugins.sso(domain_verification: {enabled: true, dns_txt_resolver: ->(_hostname) { [[@domain_verification_token]] }}), BetterAuth::Plugins.organization])
    owner_cookie = sign_up_cookie(auth, "owner@example.com")
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Org A", slug: "org-a"})
    provider = register_sso_provider(auth, owner_cookie, organization_id: organization.fetch("id"))
    @domain_verification_token = provider.fetch(:domainVerificationToken)
    admin_cookie = sign_up_cookie(auth, "admin@example.com")
    admin = auth.context.internal_adapter.find_user_by_email("admin@example.com").fetch(:user)
    auth.context.adapter.create(model: "member", data: {userId: admin.fetch("id"), organizationId: organization.fetch("id"), role: "admin"})

    response = auth.api.verify_domain(headers: {"cookie" => admin_cookie}, body: {providerId: provider.fetch("providerId")}, return_status: true)

    assert_equal 204, response.fetch(:status)
  end

  def test_verify_domain_rejects_invalid_domain
    auth = build_auth
    cookie = sign_up_cookie(auth)
    provider = register_sso_provider(auth, cookie, domain: "http://[invalid")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_domain(headers: {"cookie" => cookie}, body: {providerId: provider.fetch("providerId")})
    end

    assert_equal 400, error.status_code
    assert_equal "INVALID_DOMAIN", error.code
  end

  def test_verify_domain_rejects_long_dns_identifier
    long_provider_id = "a" * 50
    auth = build_auth
    cookie = sign_up_cookie(auth)
    register_sso_provider(auth, cookie, provider_id: long_provider_id)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_domain(headers: {"cookie" => cookie}, body: {providerId: long_provider_id})
    end

    assert_equal 400, error.status_code
    assert_equal "IDENTIFIER_TOO_LONG", error.code
    assert_equal "Verification identifier exceeds the DNS label limit of 63 characters", error.message
  end

  def test_verify_domain_returns_bad_gateway_when_dns_token_is_missing
    auth = build_auth(domain_verification: {enabled: true, dns_txt_resolver: ->(_hostname) { [["google-site-verification=the-token"]] }})
    cookie = sign_up_cookie(auth)
    provider = register_sso_provider(auth, cookie)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_domain(headers: {"cookie" => cookie}, body: {providerId: provider.fetch("providerId")})
    end

    assert_equal 502, error.status_code
    assert_equal "DOMAIN_VERIFICATION_FAILED", error.code
  end

  def test_verify_domain_rejects_txt_record_that_only_contains_expected_value_as_substring
    auth = build_auth(
      domain_verification: {
        enabled: true,
        dns_txt_resolver: ->(_hostname) { [["_better-auth-token-saml-provider-1=#{@domain_verification_token}-attacker"]] }
      }
    )
    cookie = sign_up_cookie(auth)
    provider = register_sso_provider(auth, cookie)
    @domain_verification_token = provider.fetch(:domainVerificationToken)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_domain(headers: {"cookie" => cookie}, body: {providerId: provider.fetch("providerId")})
    end

    assert_equal 502, error.status_code
    assert_equal "DOMAIN_VERIFICATION_FAILED", error.code
  end

  def test_verify_domain_fails_when_domain_is_already_verified
    auth = build_auth(
      domain_verification: {
        enabled: true,
        dns_txt_resolver: ->(_hostname) { [["_better-auth-token-saml-provider-1=#{@domain_verification_token}"]] }
      }
    )
    cookie = sign_up_cookie(auth)
    provider = register_sso_provider(auth, cookie)
    @domain_verification_token = provider.fetch(:domainVerificationToken)
    auth.api.verify_domain(headers: {"cookie" => cookie}, body: {providerId: provider.fetch("providerId")})

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_domain(headers: {"cookie" => cookie}, body: {providerId: provider.fetch("providerId")})
    end

    assert_equal 409, error.status_code
    assert_equal "DOMAIN_VERIFIED", error.code
  end

  def test_request_and_verify_domain_through_secondary_storage
    storage = MemoryStorage.new
    auth = build_auth(
      domain_verification: {enabled: true, dns_txt_resolver: ->(_hostname) { [["_better-auth-token-saml-provider-1=#{@domain_verification_token}"]] }},
      secondary_storage: storage
    )
    cookie = sign_up_cookie(auth)
    provider = register_sso_provider(auth, cookie)
    @domain_verification_token = provider.fetch(:domainVerificationToken)

    response = auth.api.request_domain_verification(headers: {"cookie" => cookie}, body: {providerId: provider.fetch("providerId")})
    assert_equal @domain_verification_token, response.fetch(:domainVerificationToken)

    verified = auth.api.verify_domain(headers: {"cookie" => cookie}, body: {providerId: provider.fetch("providerId")}, return_status: true)
    assert_equal 204, verified.fetch(:status)
    refute_empty storage.values
  end

  private

  class MemoryStorage
    attr_reader :values

    def initialize
      @values = {}
    end

    def set(key, value, _ttl = nil)
      @values[key] = value
    end

    def get(key)
      @values[key]
    end

    def delete(key)
      @values.delete(key)
    end
  end

  def build_auth(plugin_options = nil, plugins: nil, secondary_storage: nil, **kwargs)
    plugin_options = {domain_verification: {enabled: true}}.merge(plugin_options || {}).merge(kwargs)
    BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: :memory,
      email_and_password: {enabled: true},
      secondary_storage: secondary_storage,
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

  def register_sso_provider(auth, cookie, provider_id: "saml-provider-1", domain: "hello.com", organization_id: nil)
    auth.api.register_sso_provider(
      headers: {"cookie" => cookie},
      body: {
        providerId: provider_id,
        issuer: "https://idp.example.test",
        domain: domain,
        organizationId: organization_id,
        oidcConfig: {
          clientId: "client-id",
          clientSecret: "client-secret",
          skipDiscovery: true,
          authorizationEndpoint: "https://idp.example.test/authorize",
          tokenEndpoint: "https://idp.example.test/token",
          jwksEndpoint: "https://idp.example.test/jwks"
        }
      }.compact
    )
  end
end
