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

  def test_oidc_callback_rejects_trusted_provider_for_unverified_local_user_by_default
    auth = build_sso_auth(account: {account_linking: {trusted_providers: ["sso:local-gate-oidc"]}})
    owner_cookie = sign_up_cookie(auth, email: "local-gate-oidc-owner@example.com")
    sign_up_cookie(auth, email: "local-gate-oidc@example.com")
    user = auth.context.internal_adapter.find_user_by_email("local-gate-oidc@example.com").fetch(:user)
    register_oidc_provider(auth, cookie: owner_cookie, provider_id: "local-gate-oidc", domain: "example.com", oidcConfig: serializable_oidc_config)
    state = Rack::Utils.parse_query(URI.parse(auth.api.sign_in_sso(body: {providerId: "local-gate-oidc", callbackURL: "/dashboard"}).fetch(:url)).query).fetch("state")
    session_count = auth.context.adapter.find_many(model: "session").length

    with_oidc_network_stubs(email: user.fetch("email"), sub: "local-gate-oidc-sub") do
      status, headers, = auth.api.callback_sso(params: {providerId: "local-gate-oidc"}, query: {state: state, code: "good"}, as_response: true)

      assert_equal 302, status
      assert_equal "/dashboard?error=account_not_linked", headers.fetch("location")
    end
    assert_nil auth.context.internal_adapter.find_account_by_provider_id("local-gate-oidc-sub", "sso:local-gate-oidc")
    assert_equal session_count, auth.context.adapter.find_many(model: "session").length
  end

  def test_oidc_callback_links_verified_local_user
    auth = build_sso_auth(account: {account_linking: {trusted_providers: ["sso:verified-local-oidc"]}})
    owner_cookie = sign_up_cookie(auth, email: "verified-local-oidc-owner@example.com")
    sign_up_cookie(auth, email: "verified-local-oidc@example.com")
    user = auth.context.internal_adapter.find_user_by_email("verified-local-oidc@example.com").fetch(:user)
    auth.context.internal_adapter.update_user(user.fetch("id"), emailVerified: true)
    register_oidc_provider(auth, cookie: owner_cookie, provider_id: "verified-local-oidc", domain: "example.com", oidcConfig: serializable_oidc_config)
    state = Rack::Utils.parse_query(URI.parse(auth.api.sign_in_sso(body: {providerId: "verified-local-oidc", callbackURL: "/dashboard"}).fetch(:url)).query).fetch("state")

    with_oidc_network_stubs(email: user.fetch("email"), sub: "verified-local-oidc-sub") do
      _status, headers, = auth.api.callback_sso(params: {providerId: "verified-local-oidc"}, query: {state: state, code: "good"}, as_response: true)
      assert_equal "/dashboard", headers.fetch("location")
    end
    assert auth.context.internal_adapter.find_account_by_provider_id("verified-local-oidc-sub", "sso:verified-local-oidc")
  end

  def test_oidc_callback_links_verified_local_user_with_callable_provider_config
    code_verifier = nil
    auth = build_sso_auth(account: {account_linking: {trusted_providers: ["sso:callable-oidc"]}})
    owner_cookie = sign_up_cookie(auth, email: "callable-oidc-owner@example.com")
    sign_up_cookie(auth, email: "sso-user@example.com")
    user = auth.context.internal_adapter.find_user_by_email("sso-user@example.com").fetch(:user)
    auth.context.internal_adapter.update_user(user.fetch("id"), emailVerified: true)
    register_oidc_provider(
      auth,
      cookie: owner_cookie,
      provider_id: "callable-oidc",
      domain: "example.com",
      oidcConfig: {
        clientId: "client-id",
        clientSecret: "client-secret",
        skipDiscovery: true,
        pkce: true,
        authorizationEndpoint: "https://idp.example.com/authorize",
        tokenEndpoint: "https://idp.example.com/token",
        getToken: lambda do |**data|
          code_verifier = data.fetch(:codeVerifier)
          {accessToken: "access-token"}
        end,
        getUserInfo: ->(_tokens) { {id: "callable-oidc-subject", email: "sso-user@example.com", name: "Callable OIDC"} }
      }
    )
    sign_in = auth.api.sign_in_sso(body: {providerId: "callable-oidc", callbackURL: "/dashboard"})
    sign_in_params = Rack::Utils.parse_query(URI.parse(sign_in.fetch(:url)).query)
    state = sign_in_params.fetch("state")
    session_count = auth.context.internal_adapter.list_sessions(user.fetch("id")).length

    status, headers, = auth.api.callback_sso(params: {providerId: "callable-oidc"}, query: {state: state, code: "good"}, as_response: true)

    refute_empty sign_in_params.fetch("code_challenge")
    assert_equal 302, status
    assert_equal "/dashboard", headers.fetch("location")
    refute_empty code_verifier
    assert auth.context.internal_adapter.find_account_by_provider_id("callable-oidc-subject", "sso:callable-oidc")
    assert_equal session_count + 1, auth.context.internal_adapter.list_sessions(user.fetch("id")).length
  end

  def test_oidc_callback_local_verification_opt_out_supports_snake_and_camel_case
    [
      {account: {account_linking: {trusted_providers: ["sso:opt-out-oidc"], require_local_email_verified: false}}},
      {account: {accountLinking: {trustedProviders: ["sso:opt-out-oidc"], requireLocalEmailVerified: false}}}
    ].each_with_index do |options, index|
      email = "opt-out-oidc-#{index}@example.com"
      sub = "opt-out-oidc-sub-#{index}"
      auth = build_sso_auth(**options, plugin_options: {trust_email_verified: true})
      owner_cookie = sign_up_cookie(auth, email: "opt-out-oidc-owner-#{index}@example.com")
      sign_up_cookie(auth, email: email)
      local = auth.context.internal_adapter.find_user_by_email(email).fetch(:user)
      register_oidc_provider(auth, cookie: owner_cookie, provider_id: "opt-out-oidc", domain: "example.com", oidcConfig: serializable_oidc_config)
      state = Rack::Utils.parse_query(URI.parse(auth.api.sign_in_sso(body: {providerId: "opt-out-oidc", callbackURL: "/dashboard"}).fetch(:url)).query).fetch("state")

      with_oidc_network_stubs(email: email, sub: sub, email_verified: true) do
        _status, headers, = auth.api.callback_sso(params: {providerId: "opt-out-oidc"}, query: {state: state, code: "good"}, as_response: true)
        assert_equal "/dashboard", headers.fetch("location")
      end
      assert auth.context.internal_adapter.find_account_by_provider_id(sub, "sso:opt-out-oidc")
      promoted = auth.context.internal_adapter.find_user_by_id(local.fetch("id"))
      assert_equal true, promoted.fetch("emailVerified")
      refute_equal "Rack OIDC", promoted.fetch("name")
    end
  end

  def test_oidc_callback_keeps_implicit_link_when_verified_email_promotion_is_vetoed
    auth = build_sso_auth(
      account: {account_linking: {trusted_providers: ["sso:promotion-veto-oidc"], require_local_email_verified: false}},
      database_hooks: {
        user: {
          update: {
            before: ->(data, _context) { false if data["emailVerified"] == true }
          }
        }
      },
      plugin_options: {trust_email_verified: true}
    )
    owner_cookie = sign_up_cookie(auth, email: "promotion-veto-oidc-owner@example.com")
    sign_up_cookie(auth, email: "promotion-veto-oidc@example.com")
    user = auth.context.internal_adapter.find_user_by_email("promotion-veto-oidc@example.com").fetch(:user)
    session_count = auth.context.internal_adapter.list_sessions(user.fetch("id")).length
    register_oidc_provider(auth, cookie: owner_cookie, provider_id: "promotion-veto-oidc", domain: "example.com", oidcConfig: serializable_oidc_config)
    state = Rack::Utils.parse_query(URI.parse(auth.api.sign_in_sso(body: {providerId: "promotion-veto-oidc", callbackURL: "/dashboard"}).fetch(:url)).query).fetch("state")

    assert_raises(BetterAuth::Error) do
      with_oidc_network_stubs(email: user.fetch("email"), sub: "promotion-veto-oidc-sub", email_verified: true) do
        auth.api.callback_sso(params: {providerId: "promotion-veto-oidc"}, query: {state: state, code: "good"}, as_response: true)
      end
    end

    assert auth.context.internal_adapter.find_account_by_provider_id("promotion-veto-oidc-sub", "sso:promotion-veto-oidc")
    refute auth.context.internal_adapter.find_user_by_id(user.fetch("id")).fetch("emailVerified")
    assert_equal session_count, auth.context.internal_adapter.list_sessions(user.fetch("id")).length
  end

  def test_oidc_callback_respects_disable_implicit_linking_but_allows_new_user
    auth = build_sso_auth(account: {account_linking: {trusted_providers: ["sso:disabled-implicit-oidc"], disable_implicit_linking: true}})
    owner_cookie = sign_up_cookie(auth, email: "disabled-implicit-owner@example.com")
    sign_up_cookie(auth, email: "disabled-implicit-oidc@example.com")
    local = auth.context.internal_adapter.find_user_by_email("disabled-implicit-oidc@example.com").fetch(:user)
    auth.context.internal_adapter.update_user(local.fetch("id"), emailVerified: true)
    register_oidc_provider(auth, cookie: owner_cookie, provider_id: "disabled-implicit-oidc", domain: "example.com", oidcConfig: serializable_oidc_config)
    state = Rack::Utils.parse_query(URI.parse(auth.api.sign_in_sso(body: {providerId: "disabled-implicit-oidc", callbackURL: "/dashboard"}).fetch(:url)).query).fetch("state")

    with_oidc_network_stubs(email: local.fetch("email"), sub: "disabled-implicit-existing") do
      _status, headers, = auth.api.callback_sso(params: {providerId: "disabled-implicit-oidc"}, query: {state: state, code: "good"}, as_response: true)
      assert_equal "/dashboard?error=account_not_linked", headers.fetch("location")
    end

    new_state = Rack::Utils.parse_query(URI.parse(auth.api.sign_in_sso(body: {providerId: "disabled-implicit-oidc", callbackURL: "/dashboard"}).fetch(:url)).query).fetch("state")
    with_oidc_network_stubs(email: "new-disabled-implicit@example.com", sub: "disabled-implicit-new") do
      _status, headers, = auth.api.callback_sso(params: {providerId: "disabled-implicit-oidc"}, query: {state: new_state, code: "good"}, as_response: true)
      assert_equal "/dashboard", headers.fetch("location")
    end
    assert auth.context.internal_adapter.find_account_by_provider_id("disabled-implicit-new", "sso:disabled-implicit-oidc")
  end

  def test_oidc_callback_rejects_whitespace_remote_id_without_persistence
    auth = build_sso_auth
    owner_cookie = sign_up_cookie(auth, email: "blank-oidc-owner@example.com")
    register_oidc_provider(auth, cookie: owner_cookie, provider_id: "blank-oidc", domain: "example.com", oidcConfig: serializable_oidc_config)
    state = Rack::Utils.parse_query(URI.parse(auth.api.sign_in_sso(body: {providerId: "blank-oidc", callbackURL: "/dashboard"}).fetch(:url)).query).fetch("state")
    session_count = auth.context.adapter.find_many(model: "session").length

    with_oidc_network_stubs(email: "blank-oidc@example.com", sub: " \t ") do
      _status, headers, = auth.api.callback_sso(params: {providerId: "blank-oidc"}, query: {state: state, code: "good"}, as_response: true)
      assert_equal "/dashboard?error=invalid_provider", headers.fetch("location")
    end
    assert_nil auth.context.internal_adapter.find_user_by_email("blank-oidc@example.com")
    assert_empty auth.context.adapter.find_many(model: "account").select { |account| account["accountId"].to_s.strip.empty? }
    assert_equal session_count, auth.context.adapter.find_many(model: "session").length
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

  def with_oidc_network_stubs(email: "rack-callback-user@example.com", sub: "rack-callback-sub", email_verified: false)
    with_singleton_method(BetterAuth::Plugins, :sso_exchange_oidc_code, ->(**_kwargs) { {accessToken: "rack-token"} }) do
      with_singleton_method(BetterAuth::Plugins, :sso_fetch_oidc_user_info, ->(_endpoint, _access_token, **_kwargs) {
        {sub: sub, email: email, email_verified: email_verified, name: "Rack OIDC"}
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
