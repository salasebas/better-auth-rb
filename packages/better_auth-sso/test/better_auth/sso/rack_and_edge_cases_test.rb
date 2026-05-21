# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../support/sso_test_helpers"

class BetterAuthSSORackAndEdgeCasesTest < Minitest::Test
  include BetterAuthSSOTestHelpers

  def test_rack_mounted_sign_in_sso_uses_base_path_redirect_uri
    auth = build_sso_auth
    cookie = sign_up_cookie(auth)
    register_oidc_provider(auth, cookie: cookie, provider_id: "rack-oidc", domain: "rack.example.com")

    status, _headers, body = rack_json_request(auth, "POST", "/api/auth/sign-in/sso", body: {providerId: "rack-oidc", callbackURL: "/dashboard"})
    payload = response_json(body)
    params = Rack::Utils.parse_query(URI.parse(payload.fetch("url")).query)

    assert_equal 200, status
    assert_equal true, payload.fetch("redirect")
    assert_equal "http://localhost:3000/api/auth/sso/callback/rack-oidc", params.fetch("redirect_uri")
  end

  def test_rack_mounted_oidc_callback_creates_session
    auth = build_sso_auth
    cookie = sign_up_cookie(auth)
    register_oidc_provider(auth, cookie: cookie, provider_id: "rack-callback-oidc", domain: "rack-callback.example.com", oidcConfig: serializable_oidc_config)
    state = Rack::Utils.parse_query(URI.parse(auth.api.sign_in_sso(body: {providerId: "rack-callback-oidc", callbackURL: "/dashboard"}).fetch(:url)).query).fetch("state")

    with_oidc_network_stubs do
      status, headers, _body = rack_json_request(auth, "GET", "/api/auth/sso/callback/rack-callback-oidc?state=#{URI.encode_www_form_component(state)}&code=good")

      assert_equal 302, status
      assert_equal "/dashboard", headers.fetch("location")
      assert headers.fetch("set-cookie").include?("better-auth.session_token=")
    end
  end

  def test_rack_mounted_saml_acs_allows_external_idp_origin_but_other_posts_still_require_trusted_origin
    auth = build_sso_auth(plugin_options: {saml: {parse_response: ->(**_data) { {id: "rack-saml", email: "rack-saml@example.com", name: "Rack SAML"} }}})
    cookie = sign_up_cookie(auth)
    register_saml_provider(auth, cookie: cookie, provider_id: "rack-saml")

    acs_status, acs_headers, _acs_body = rack_form_request(
      auth,
      "POST",
      "/api/auth/sso/saml2/sp/acs/rack-saml",
      origin: "https://external-idp.example.com",
      form: {SAMLResponse: saml_response_xml(assertion_id: "rack-saml")}
    )
    blocked_status, _blocked_headers, blocked_body = rack_json_request(
      auth,
      "POST",
      "/api/auth/sso/register",
      cookie: cookie,
      origin: "https://attacker.example.com",
      body: {
        providerId: "attacker-provider",
        issuer: "https://idp.example.com",
        domain: "attacker.example.com",
        oidcConfig: serializable_oidc_config
      }
    )

    assert_equal 302, acs_status
    assert_equal "/", acs_headers.fetch("location")
    assert_equal 403, blocked_status
    assert_equal "Invalid origin", response_json(blocked_body).fetch("message")
  end

  def test_serialized_oidc_config_round_trips_through_sign_in_and_callback
    auth = build_sso_auth
    cookie = sign_up_cookie(auth)
    register_oidc_provider(auth, cookie: cookie, provider_id: "serialized-oidc", domain: "serialized.example.com", oidcConfig: serializable_oidc_config)
    provider = auth.context.adapter.find_one(model: "ssoProvider", where: [{field: "providerId", value: "serialized-oidc"}])
    auth.context.adapter.update(
      model: "ssoProvider",
      where: [{field: "id", value: provider.fetch("id")}],
      update: {oidcConfig: JSON.generate(serializable_oidc_config)}
    )

    sign_in = auth.api.sign_in_sso(body: {providerId: "serialized-oidc", callbackURL: "/dashboard"})
    state = Rack::Utils.parse_query(URI.parse(sign_in.fetch(:url)).query).fetch("state")

    with_oidc_network_stubs(email: "serialized-user@example.com", sub: "serialized-sub") do
      status, headers, _body = auth.api.callback_sso(params: {providerId: "serialized-oidc"}, query: {state: state, code: "good"}, as_response: true)

      assert_equal 302, status
      assert_equal "/dashboard", headers.fetch("location")
      assert auth.context.internal_adapter.find_user_by_email("serialized-user@example.com")
      assert auth.context.internal_adapter.find_account_by_provider_id("serialized-sub", "sso:serialized-oidc")
    end
  end

  def test_provider_ids_are_encoded_in_oidc_redirect_uri_and_saml_metadata_urls
    auth = build_sso_auth
    cookie = sign_up_cookie(auth)
    provider = register_oidc_provider(auth, cookie: cookie, provider_id: "team alpha", domain: "team-alpha.example.com")

    assert_includes provider.fetch(:redirectURI), "/sso/callback/team+alpha"
    assert_includes provider.fetch("spMetadataUrl"), "providerId=team+alpha"
  end

  def test_oidc_error_callback_rejects_cross_origin_and_protocol_relative_redirects
    auth = build_sso_auth
    cookie = sign_up_cookie(auth)
    register_oidc_provider(auth, cookie: cookie, provider_id: "safe-oidc", domain: "safe.example.com")

    cross_origin_state = auth.api.sign_in_sso(
      body: {
        providerId: "safe-oidc",
        callbackURL: "https://evil.example.com/callback",
        errorCallbackURL: "//evil.example.com/error"
      }
    ).fetch(:url)
    state = Rack::Utils.parse_query(URI.parse(cross_origin_state).query).fetch("state")

    status, headers, _body = auth.api.callback_sso(
      params: {providerId: "safe-oidc"},
      query: {state: state, error: "access_denied", error_description: "Nope"},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "http://localhost:3000/api/auth?error=access_denied&error_description=Nope", headers.fetch("location")
  end

  def test_duplicate_domain_selection_uses_first_registered_provider
    auth = build_sso_auth
    cookie = sign_up_cookie(auth)
    register_oidc_provider(auth, cookie: cookie, provider_id: "first-domain", domain: "duplicate.example.com")
    register_oidc_provider(auth, cookie: cookie, provider_id: "second-domain", domain: "duplicate.example.com")

    sign_in = auth.api.sign_in_sso(body: {email: "ada@duplicate.example.com", callbackURL: "/dashboard"})
    params = Rack::Utils.parse_query(URI.parse(sign_in.fetch(:url)).query)
    state = BetterAuth::Crypto.verify_jwt(params.fetch("state"), SECRET)

    assert_equal "first-domain", state.fetch("providerId")
    assert_equal "client-id", params.fetch("client_id")
  end

  private

  def serializable_oidc_config
    {
      clientId: "client-id",
      clientSecret: "client-secret",
      skipDiscovery: true,
      pkce: false,
      authorizationEndpoint: "https://idp.example.com/authorize",
      tokenEndpoint: "https://idp.example.com/token",
      userInfoEndpoint: "https://idp.example.com/userinfo",
      jwksEndpoint: "https://idp.example.com/jwks",
      mapping: {
        id: "sub",
        email: "email",
        name: "name"
      }
    }
  end

  def with_oidc_network_stubs(email: "rack-callback-user@example.com", sub: "rack-callback-sub")
    with_singleton_method(BetterAuth::Plugins, :sso_exchange_oidc_code, ->(**_kwargs) { {accessToken: "rack-token"} }) do
      with_singleton_method(BetterAuth::Plugins, :sso_fetch_oidc_user_info, ->(_endpoint, _access_token, **_kwargs) {
        {sub: sub, email: email, name: "Rack OIDC"}
      }) do
        yield
      end
    end
  end

  def with_singleton_method(object, method_name, replacement)
    singleton_class = class << object; self; end
    original = singleton_class.instance_method(method_name)
    redefine_without_warning(singleton_class, method_name) { |*args, **kwargs, &block| replacement.call(*args, **kwargs, &block) }
    yield
  ensure
    redefine_without_warning(singleton_class, method_name, original)
  end

  def redefine_without_warning(singleton_class, method_name, original = nil, &block)
    previous_verbose = $VERBOSE
    $VERBOSE = nil
    original ? singleton_class.define_method(method_name, original) : singleton_class.define_method(method_name, &block)
  ensure
    $VERBOSE = previous_verbose
  end
end
