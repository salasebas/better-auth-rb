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
    _sign_in_status, sign_in_headers, sign_in_body = rack_json_request(
      auth,
      "POST",
      "/api/auth/sign-in/sso",
      body: {providerId: "rack-callback-oidc", callbackURL: "/dashboard"}
    )
    state = Rack::Utils.parse_query(URI.parse(response_json(sign_in_body).fetch("url")).query).fetch("state")
    state_cookie = cookie_header(sign_in_headers.fetch("set-cookie"))

    with_oidc_network_stubs do
      status, headers, _body = rack_json_request(
        auth,
        "GET",
        "/api/auth/sso/callback/rack-callback-oidc?state=#{URI.encode_www_form_component(state)}&code=good",
        cookie: state_cookie
      )

      assert_equal 302, status
      assert_equal "/dashboard", headers.fetch("location")
      assert headers.fetch("set-cookie").include?("better-auth.session_token=")
    end
  end

  def test_rack_oidc_non_pkce_requires_issued_state_cookie_and_consumes_shared_state
    token_requests = []
    auth = build_sso_auth
    cookie = sign_up_cookie(auth)
    register_oidc_provider(
      auth,
      cookie: cookie,
      provider_id: "shared-state-non-pkce",
      domain: "shared-state-non-pkce.example.com",
      oidcConfig: rack_oidc_config(pkce: false, token_requests: token_requests)
    )

    sign_in_status, sign_in_headers, sign_in_body = rack_json_request(
      auth,
      "POST",
      "/api/auth/sign-in/sso",
      body: {providerId: "shared-state-non-pkce", callbackURL: "/dashboard"}
    )
    state = Rack::Utils.parse_query(URI.parse(response_json(sign_in_body).fetch("url")).query).fetch("state")
    state_cookie = cookie_header(sign_in_headers.fetch("set-cookie"))
    stored_state = auth.context.internal_adapter.find_verification_value(state)

    assert_equal 200, sign_in_status
    assert_equal 32, state.length
    refute BetterAuth::Crypto.verify_jwt(state, SECRET)
    assert_includes state_cookie, "better-auth.state="
    assert_equal(
      {
        "callbackURL" => "/dashboard",
        "codeVerifier" => stored_state_data(stored_state).fetch("codeVerifier"),
        "oauthState" => state
      },
      stored_state_data(stored_state).slice("callbackURL", "codeVerifier", "oauthState")
    )
    assert_equal 128, stored_state_data(stored_state).fetch("codeVerifier").length
    assert_nil auth.context.internal_adapter.find_verification_value("oidc-pkce-verifier:#{state}")

    missing_cookie_status, missing_cookie_headers, = rack_json_request(
      auth,
      "GET",
      "/api/auth/sso/callback/shared-state-non-pkce?state=#{URI.encode_www_form_component(state)}&code=good"
    )

    assert_equal 302, missing_cookie_status
    assert_equal "http://localhost:3000/api/auth/error?error=state_mismatch", missing_cookie_headers.fetch("location")
    assert auth.context.internal_adapter.find_verification_value(state)

    callback_status, callback_headers, = rack_json_request(
      auth,
      "GET",
      "/api/auth/sso/callback/shared-state-non-pkce?state=#{URI.encode_www_form_component(state)}&code=good",
      cookie: state_cookie
    )

    assert_equal 302, callback_status
    assert_equal "/dashboard", callback_headers.fetch("location")
    assert_equal [nil], token_requests.map { |request| request[:codeVerifier] }
    assert_nil auth.context.internal_adapter.find_verification_value(state)

    replay_status, replay_headers, = rack_json_request(
      auth,
      "GET",
      "/api/auth/sso/callback/shared-state-non-pkce?state=#{URI.encode_www_form_component(state)}&code=replay",
      cookie: state_cookie
    )

    assert_equal 302, replay_status
    assert_equal "http://localhost:3000/api/auth/error?error=state_mismatch", replay_headers.fetch("location")
  end

  def test_rack_oidc_pkce_reads_verifier_from_shared_state
    token_requests = []
    auth = build_sso_auth
    cookie = sign_up_cookie(auth)
    register_oidc_provider(
      auth,
      cookie: cookie,
      provider_id: "shared-state-pkce",
      domain: "shared-state-pkce.example.com",
      oidcConfig: rack_oidc_config(pkce: true, token_requests: token_requests)
    )

    _sign_in_status, sign_in_headers, sign_in_body = rack_json_request(
      auth,
      "POST",
      "/api/auth/sign-in/sso",
      body: {providerId: "shared-state-pkce", callbackURL: "/dashboard"}
    )
    authorization_params = Rack::Utils.parse_query(URI.parse(response_json(sign_in_body).fetch("url")).query)
    state = authorization_params.fetch("state")
    state_cookie = cookie_header(sign_in_headers.fetch("set-cookie"))
    stored_state = auth.context.internal_adapter.find_verification_value(state)
    verifier = stored_state_data(stored_state).fetch("codeVerifier")

    assert_equal 32, state.length
    assert_equal "S256", authorization_params.fetch("code_challenge_method")
    assert authorization_params.fetch("code_challenge")
    assert_equal 128, verifier.length
    assert_nil auth.context.internal_adapter.find_verification_value("oidc-pkce-verifier:#{state}")

    callback_status, callback_headers, = rack_json_request(
      auth,
      "GET",
      "/api/auth/sso/callback/shared-state-pkce?state=#{URI.encode_www_form_component(state)}&code=good",
      cookie: state_cookie
    )

    assert_equal 302, callback_status
    assert_equal "/dashboard", callback_headers.fetch("location")
    assert_equal [verifier], token_requests.map { |request| request[:codeVerifier] }
    assert_nil auth.context.internal_adapter.find_verification_value(state)
  end

  def test_rack_oidc_rejects_legacy_jwt_state_without_shared_verification
    token_requests = []
    auth = build_sso_auth
    cookie = sign_up_cookie(auth)
    register_oidc_provider(
      auth,
      cookie: cookie,
      provider_id: "legacy-jwt-oidc",
      domain: "legacy-jwt-oidc.example.com",
      oidcConfig: rack_oidc_config(pkce: false, token_requests: token_requests)
    )
    state = BetterAuth::Crypto.sign_jwt(
      {providerId: "legacy-jwt-oidc", callbackURL: "/dashboard"},
      SECRET,
      expires_in: 600
    )
    state_cookie = signed_state_cookie(auth, state)

    status, headers, = rack_json_request(
      auth,
      "GET",
      "/api/auth/sso/callback/legacy-jwt-oidc?state=#{URI.encode_www_form_component(state)}&code=good",
      cookie: state_cookie
    )

    assert_equal 302, status
    assert_equal "http://localhost:3000/api/auth/error?error=state_mismatch", headers.fetch("location")
    assert_empty token_requests
  end

  def test_rack_oidc_secondary_storage_keeps_shared_state_and_verifier_together
    token_requests = []
    storage = SecondaryStorage.new
    auth = build_sso_auth(secondary_storage: storage)
    cookie = sign_up_cookie(auth)
    register_oidc_provider(
      auth,
      cookie: cookie,
      provider_id: "secondary-shared-state",
      domain: "secondary-shared-state.example.com",
      oidcConfig: rack_oidc_config(pkce: true, token_requests: token_requests)
    )

    _sign_in_status, sign_in_headers, sign_in_body = rack_json_request(
      auth,
      "POST",
      "/api/auth/sign-in/sso",
      body: {providerId: "secondary-shared-state", callbackURL: "/dashboard"}
    )
    state = Rack::Utils.parse_query(URI.parse(response_json(sign_in_body).fetch("url")).query).fetch("state")
    state_cookie = cookie_header(sign_in_headers.fetch("set-cookie"))
    state_key = "verification:#{state}"
    stored_state = JSON.parse(storage.get(state_key))

    assert_equal state, stored_state.fetch("identifier")
    assert_equal state, JSON.parse(stored_state.fetch("value")).fetch("oauthState")
    assert_equal 128, JSON.parse(stored_state.fetch("value")).fetch("codeVerifier").length
    assert_in_delta 600, storage.ttls.fetch(state_key), 2
    assert_nil storage.get("verification:oidc-pkce-verifier:#{state}")

    callback_status, callback_headers, = rack_json_request(
      auth,
      "GET",
      "/api/auth/sso/callback/secondary-shared-state?state=#{URI.encode_www_form_component(state)}&code=good",
      cookie: state_cookie
    )

    assert_equal 302, callback_status
    assert_equal "/dashboard", callback_headers.fetch("location")
    assert_equal 1, token_requests.length
    assert_nil storage.get(state_key)
  end

  def test_rack_mounted_saml_acs_allows_external_idp_origin_but_other_posts_still_require_trusted_origin
    sso_plugin = BetterAuth::Plugins.sso(saml: {parse_response: ->(**_data) { {id: "rack-saml", email: "rack-saml@example.com", name: "Rack SAML"} }})
    adjacent_plugin = {
      id: "adjacent-saml-path",
      endpoints: {
        acs_evil: BetterAuth::Endpoint.new(path: "/sso/saml2/sp/acsevil", method: "POST") { {ok: true} }
      }
    }
    auth = build_sso_auth(plugins: [sso_plugin, adjacent_plugin])
    cookie = sign_up_cookie(auth)
    register_saml_provider(auth, cookie: cookie, provider_id: "rack-saml")

    acs_status, acs_headers, _acs_body = rack_form_request(
      auth,
      "POST",
      "/api/auth/sso/saml2/sp/acs/rack-saml",
      cookie: cookie,
      origin: "https://external-idp.example.com",
      form: {SAMLResponse: saml_response_xml(assertion_id: "rack-saml")}
    )
    blocked_status, _blocked_headers, blocked_body = rack_json_request(
      auth,
      "POST",
      "/api/auth/sso/saml2/sp/acsevil",
      cookie: cookie,
      origin: "https://attacker.example.com",
      body: {}
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
      assert_equal "http://localhost:3000/api/auth/error?error=account_not_linked", headers.fetch("location")
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
      assert_equal "http://localhost:3000/api/auth/error?error=account_not_linked", headers.fetch("location")
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
      assert_equal "http://localhost:3000/api/auth/error?error=invalid_provider", headers.fetch("location")
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

  def test_rack_oidc_idp_error_uses_global_error_url_without_per_flow_error_url
    auth = build_sso_auth(on_api_error: {error_url: "http://localhost:3000/global-error"})
    cookie = sign_up_cookie(auth)
    register_oidc_provider(
      auth,
      cookie: cookie,
      provider_id: "global-oidc-error",
      domain: "global-oidc-error.example.com",
      oidcConfig: rack_oidc_config(pkce: false, token_requests: [])
    )

    _sign_in_status, sign_in_headers, sign_in_body = rack_json_request(
      auth,
      "POST",
      "/api/auth/sign-in/sso",
      body: {providerId: "global-oidc-error", callbackURL: "/dashboard"}
    )
    state = Rack::Utils.parse_query(URI.parse(response_json(sign_in_body).fetch("url")).query).fetch("state")
    state_cookie = cookie_header(sign_in_headers.fetch("set-cookie"))

    status, headers, = rack_json_request(
      auth,
      "GET",
      "/api/auth/sso/callback/global-oidc-error?state=#{URI.encode_www_form_component(state)}&error=access_denied&error_description=cancelled",
      cookie: state_cookie
    )

    assert_equal 302, status
    assert_equal "http://localhost:3000/global-error?error=access_denied&error_description=cancelled", headers.fetch("location")
  end

  def test_rack_oidc_idp_error_preserves_per_flow_error_url_over_global_error_url
    auth = build_sso_auth(on_api_error: {error_url: "http://localhost:3000/global-error"})
    cookie = sign_up_cookie(auth)
    register_oidc_provider(
      auth,
      cookie: cookie,
      provider_id: "per-flow-oidc-error",
      domain: "per-flow-oidc-error.example.com",
      oidcConfig: rack_oidc_config(pkce: false, token_requests: [])
    )

    _sign_in_status, sign_in_headers, sign_in_body = rack_json_request(
      auth,
      "POST",
      "/api/auth/sign-in/sso",
      body: {
        providerId: "per-flow-oidc-error",
        callbackURL: "/dashboard",
        errorCallbackURL: "/per-flow-error"
      }
    )
    state = Rack::Utils.parse_query(URI.parse(response_json(sign_in_body).fetch("url")).query).fetch("state")
    state_cookie = cookie_header(sign_in_headers.fetch("set-cookie"))

    status, headers, = rack_json_request(
      auth,
      "GET",
      "/api/auth/sso/callback/per-flow-oidc-error?state=#{URI.encode_www_form_component(state)}&error=access_denied&error_description=cancelled",
      cookie: state_cookie
    )

    assert_equal 302, status
    assert_equal "/per-flow-error?error=access_denied&error_description=cancelled", headers.fetch("location")
  end

  def test_duplicate_domain_selection_uses_first_registered_provider
    auth = build_sso_auth
    cookie = sign_up_cookie(auth)
    register_oidc_provider(auth, cookie: cookie, provider_id: "first-domain", domain: "duplicate.example.com")
    register_oidc_provider(auth, cookie: cookie, provider_id: "second-domain", domain: "duplicate.example.com")

    sign_in = auth.api.sign_in_sso(body: {email: "ada@duplicate.example.com", callbackURL: "/dashboard"})
    params = Rack::Utils.parse_query(URI.parse(sign_in.fetch(:url)).query)

    assert_equal 32, params.fetch("state").length
    refute BetterAuth::Crypto.verify_jwt(params.fetch("state"), SECRET)
    assert_equal "client-id", params.fetch("client_id")
  end

  private

  def rack_oidc_config(pkce:, token_requests:)
    {
      clientId: "client-id",
      clientSecret: "client-secret",
      skipDiscovery: true,
      pkce: pkce,
      authorizationEndpoint: "https://idp.example.com/authorize",
      tokenEndpoint: "https://idp.example.com/token",
      getToken: ->(**data) {
        token_requests << data
        {accessToken: "access-token"}
      },
      getUserInfo: ->(_tokens) { {id: "shared-state-sub", email: "shared-state@example.com", name: "Shared State"} }
    }
  end

  def stored_state_data(verification)
    JSON.parse(verification.fetch("value"))
  end

  def signed_state_cookie(auth, state)
    cookie = auth.context.create_auth_cookie("state")
    signature = BetterAuth::Crypto.hmac_signature(state, SECRET, encoding: :base64url)
    BetterAuth::Cookies.set_request_cookie("", cookie.name, "#{state}.#{signature}")
  end

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
