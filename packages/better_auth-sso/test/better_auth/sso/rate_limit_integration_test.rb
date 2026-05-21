# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../support/sso_test_helpers"

class BetterAuthSSORateLimitIntegrationTest < Minitest::Test
  include BetterAuthSSOTestHelpers

  def test_sign_in_sso_is_limited_with_default_memory_storage
    auth = rate_limited_auth(window: 10, max: 100)
    cookie = sign_up_cookie(auth)
    register_oidc_provider(auth, cookie: cookie, provider_id: "memory-oidc", domain: "memory.example.com")

    3.times do
      assert_equal 200, rack_json_request(auth, "POST", "/api/auth/sign-in/sso", body: {providerId: "memory-oidc", callbackURL: "/dashboard"}).first
    end
    second = rack_json_request(auth, "POST", "/api/auth/sign-in/sso", body: {providerId: "memory-oidc", callbackURL: "/dashboard"})

    assert_equal 429, second.first
    assert_equal "Too many requests. Please try again later.", response_json(second[2]).fetch("message")
  end

  def test_register_sso_provider_is_limited_with_custom_storage
    storage = RateLimitStorage.new
    auth = rate_limited_auth(custom_storage: storage, custom_rules: {"/sso/register" => {window: 60, max: 1}})
    cookie = sign_up_cookie(auth)

    first = rack_json_request(auth, "POST", "/api/auth/sso/register", cookie: cookie, body: oidc_registration_body("custom-one"))
    second = rack_json_request(auth, "POST", "/api/auth/sso/register", cookie: cookie, body: oidc_registration_body("custom-two"))

    assert_equal 200, first.first
    assert_equal 429, second.first
    assert_equal ["127.0.0.1|/sso/register"], storage.keys
  end

  def test_request_domain_verification_is_limited_with_secondary_storage
    storage = SecondaryStorage.new
    auth = rate_limited_auth(
      secondary_storage: storage,
      storage: "secondary-storage",
      plugin_options: {domain_verification: {enabled: true}},
      max: 1
    )
    cookie = sign_up_cookie(auth)
    provider = register_oidc_provider(auth, cookie: cookie, provider_id: "secondary-domain", domain: "secondary.example.com")

    first = rack_json_request(auth, "POST", "/api/auth/sso/request-domain-verification", cookie: cookie, body: {providerId: provider.fetch("providerId")})
    second = rack_json_request(auth, "POST", "/api/auth/sso/request-domain-verification", cookie: cookie, body: {providerId: provider.fetch("providerId")})

    assert_equal 201, first.first
    assert_equal 429, second.first
    stored = JSON.parse(storage.data.fetch("127.0.0.1|/sso/request-domain-verification"))
    assert_equal ["count", "key", "lastRequest"], stored.keys.sort
    assert_equal 60, storage.ttls.fetch("127.0.0.1|/sso/request-domain-verification")
  end

  def test_verify_domain_is_limited_with_database_storage
    auth = rate_limited_auth(
      storage: "database",
      plugin_options: {
        domain_verification: {
          enabled: true,
          dns_txt_resolver: ->(_hostname) { [["_better-auth-token-database-domain=#{@domain_token}"]] }
        }
      },
      max: 1
    )
    cookie = sign_up_cookie(auth)
    provider = register_oidc_provider(auth, cookie: cookie, provider_id: "database-domain", domain: "database.example.com")
    @domain_token = provider.fetch(:domainVerificationToken)

    first = rack_json_request(auth, "POST", "/api/auth/sso/verify-domain", cookie: cookie, body: {providerId: provider.fetch("providerId")})
    second = rack_json_request(auth, "POST", "/api/auth/sso/verify-domain", cookie: cookie, body: {providerId: provider.fetch("providerId")})

    assert_equal 204, first.first
    assert_equal 429, second.first
    stored = auth.context.adapter.find_one(model: "rateLimit", where: [{field: "key", value: "127.0.0.1|/sso/verify-domain"}])
    assert_equal 1, stored.fetch("count")
  end

  def test_saml_acs_rate_limit_does_not_consume_authn_request_state
    auth = rate_limited_auth(
      plugin_options: {saml: {parse_response: ->(**_data) { {id: "rate-saml", email: "rate-saml@example.com", name: "Rate SAML"} }}},
      max: 1
    )
    cookie = sign_up_cookie(auth)
    register_saml_provider(auth, cookie: cookie, provider_id: "rate-saml")
    sign_in = auth.api.sign_in_sso(body: {providerId: "rate-saml", callbackURL: "/dashboard"})
    request_id = saml_request_id_from_url(sign_in.fetch(:url))
    relay_state = Rack::Utils.parse_query(URI.parse(sign_in.fetch(:url)).query).fetch("RelayState")

    rack_form_request(auth, "POST", "/api/auth/sso/saml2/sp/acs/rate-saml", form: {SAMLResponse: saml_response_xml})
    limited = rack_form_request(
      auth,
      "POST",
      "/api/auth/sso/saml2/sp/acs/rate-saml",
      form: {SAMLResponse: saml_response_xml(in_response_to: request_id), RelayState: relay_state}
    )

    assert_equal 429, limited.first
    assert auth.context.internal_adapter.find_verification_value("saml-authn-request:#{request_id}")
  end

  def test_oidc_callback_rate_limit_does_not_consume_pkce_state
    auth = rate_limited_auth(custom_rules: {"/sso/callback/*" => {window: 60, max: 1}})
    cookie = sign_up_cookie(auth)
    register_oidc_provider(auth, cookie: cookie, provider_id: "rate-oidc", domain: "oidc.example.com")
    sign_in = auth.api.sign_in_sso(body: {providerId: "rate-oidc", callbackURL: "/dashboard"})
    state = Rack::Utils.parse_query(URI.parse(sign_in.fetch(:url)).query).fetch("state")

    rack_json_request(auth, "GET", "/api/auth/sso/callback/rate-oidc?state=bad-state&code=bad")
    limited = rack_json_request(auth, "GET", "/api/auth/sso/callback/rate-oidc?state=#{URI.encode_www_form_component(state)}&code=good")

    assert_equal 429, limited.first
    assert auth.context.internal_adapter.find_verification_value("oidc-pkce-verifier:#{state}")
  end

  private

  def rate_limited_auth(plugin_options: {}, custom_rules: {}, **rate_limit)
    auth_options = {}
    auth_options[:secondary_storage] = rate_limit.delete(:secondary_storage) if rate_limit.key?(:secondary_storage)
    build_sso_auth(
      plugin_options: plugin_options,
      rate_limit: {enabled: true, window: 60, max: 100, custom_rules: custom_rules}.merge(rate_limit),
      **auth_options
    )
  end

  def oidc_registration_body(provider_id)
    {
      providerId: provider_id,
      issuer: "https://idp.example.com",
      domain: "#{provider_id}.example.com",
      oidcConfig: {
        clientId: "client-id",
        clientSecret: "client-secret",
        skipDiscovery: true,
        authorizationEndpoint: "https://idp.example.com/authorize",
        tokenEndpoint: "https://idp.example.com/token",
        jwksEndpoint: "https://idp.example.com/jwks"
      }
    }
  end
end
