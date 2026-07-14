# frozen_string_literal: true

require "json"
require "rack/mock"
require "socket"
require_relative "../../test_helper"

class BetterAuthPluginsGenericOAuthTest < Minitest::Test
  SECRET = "phase-eight-secret-with-enough-entropy-123"
  BetterAuth::Plugins.generic_oauth(config: [])

  def test_oauth2_callback_endpoint_is_get_only_like_upstream
    auth = build_auth

    assert_equal ["GET"], auth.api.endpoints.fetch(:oauth2_callback).methods
  end

  def test_sign_in_oauth2_generates_authorization_url_with_state_and_scopes
    auth = build_auth

    result = auth.api.sign_in_with_oauth2(
      body: {
        providerId: "custom",
        callbackURL: "/dashboard",
        newUserCallbackURL: "/welcome",
        scopes: ["calendar"],
        disableRedirect: true
      }
    )
    uri = URI.parse(result[:url])
    params = Rack::Utils.parse_query(uri.query)

    assert_equal false, result[:redirect]
    assert_equal "https", uri.scheme
    assert_equal "provider.example.com", uri.host
    assert_equal "/authorize", uri.path
    assert_equal "client-id", params["client_id"]
    assert_equal "code", params["response_type"]
    assert_equal "calendar profile email", params["scope"]
    assert_equal "http://localhost:3000/api/auth/oauth2/callback/custom", params["redirect_uri"]
    assert params["state"]
  end

  def test_default_redirect_uri_stays_canonical_on_an_alternate_serving_origin
    auth = build_auth(
      base_url: "https://auth.example.com",
      serving_origins: ["https://tenant.example.com"]
    )

    result = auth.api.sign_in_with_oauth2(
      headers: {"host" => "tenant.example.com"},
      body: {providerId: "custom", disableRedirect: true}
    )
    params = Rack::Utils.parse_query(URI.parse(result.fetch(:url)).query)

    assert_equal "https://auth.example.com/api/auth/oauth2/callback/custom", params.fetch("redirect_uri")
  end

  def test_sign_in_oauth2_supports_dynamic_authorization_params_and_response_mode
    auth = build_auth(
      provider_overrides: {
        authorization_url_params: ->(ctx) { {audience: "api", origin: ctx.context.base_url} },
        response_mode: "query"
      }
    )

    result = auth.api.sign_in_with_oauth2(body: {providerId: "custom", disableRedirect: true})
    params = Rack::Utils.parse_query(URI.parse(result[:url]).query)

    assert_equal "api", params.fetch("audience")
    assert_equal "http://localhost:3000/api/auth", params.fetch("origin")
    assert_equal "query", params.fetch("response_mode")
  end

  def test_sign_in_oauth2_authorization_params_replace_defaults_and_existing_query_params
    auth = build_auth(
      provider_overrides: {
        authorization_url: "https://provider.example.com/authorize?resource=a&resource=b&scope=old-scope&prompt=login&response_type=old",
        authorizationUrlParams: ->(_ctx) {
          {
            scope: "custom-scope",
            prompt: "consent",
            response_type: "token",
            audience: "api"
          }
        },
        prompt: "select_account"
      }
    )

    result = auth.api.sign_in_with_oauth2(body: {providerId: "custom", disableRedirect: true})
    pairs = URI.decode_www_form(URI.parse(result[:url]).query)
    params = pairs.to_h

    assert_equal "custom-scope", params.fetch("scope")
    assert_equal "consent", params.fetch("prompt")
    assert_equal "token", params.fetch("response_type")
    assert_equal "api", params.fetch("audience")
    resource_values = pairs.each_with_object([]) do |(name, value), values|
      values << value if name == "resource"
    end
    assert_equal ["a", "b"], resource_values
    assert_equal ["scope", "prompt", "response_type", "audience"], %w[scope prompt response_type audience].select { |key| pairs.count { |name, _value| name == key } == 1 }
  end

  def test_pkce_uses_s256_challenge_and_token_exchange_only_sends_verifier_when_enabled
    requests = []
    with_oauth_server(requests) do |base_url|
      auth = build_auth(
        provider_overrides: {
          get_token: nil,
          get_user_info: nil,
          authorization_url: "#{base_url}/authorize",
          token_url: "#{base_url}/token",
          user_info_url: "#{base_url}/userinfo",
          pkce: true
        }
      )
      _status, headers, body = auth.api.sign_in_with_oauth2(
        body: {providerId: "custom", callbackURL: "/dashboard"},
        as_response: true
      )
      data = JSON.parse(body.join)
      params = Rack::Utils.parse_query(URI.parse(data.fetch("url")).query)
      state = params.fetch("state")

      assert_equal "S256", params.fetch("code_challenge_method")
      auth.api.oauth2_callback(
        params: {providerId: "custom"},
        query: {code: "oauth-code", state: state},
        headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))},
        as_response: true
      )

      assert requests.find { |request| request[:path] == "/token" }.fetch(:params).key?("code_verifier")
    end

    requests = []
    with_oauth_server(requests) do |base_url|
      auth = build_auth(
        provider_overrides: {
          get_token: nil,
          get_user_info: nil,
          authorization_url: "#{base_url}/authorize",
          token_url: "#{base_url}/token",
          user_info_url: "#{base_url}/userinfo",
          pkce: false
        }
      )
      _status, headers, body = auth.api.sign_in_with_oauth2(
        body: {providerId: "custom", callbackURL: "/dashboard"},
        as_response: true
      )
      params = Rack::Utils.parse_query(URI.parse(JSON.parse(body.join).fetch("url")).query)

      refute params.key?("code_challenge")
      refute params.key?("code_challenge_method")

      auth.api.oauth2_callback(
        params: {providerId: "custom"},
        query: {code: "oauth-code", state: params.fetch("state")},
        headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))},
        as_response: true
      )

      refute requests.find { |request| request[:path] == "/token" }.fetch(:params).key?("code_verifier")
    end
  end

  def test_callback_without_state_redirects_to_restart_error
    auth = build_auth(on_api_error: {error_url: "/error"})

    status, headers, = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code"},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/error?error=please_restart_the_process", headers.fetch("location")
  end

  def test_callback_preserves_provider_error_description_and_existing_error_query
    auth = build_auth(on_api_error: {error_url: "/fallback-error"})
    sign_in = auth.api.sign_in_with_oauth2(
      body: {
        providerId: "custom",
        callbackURL: "/dashboard",
        errorCallbackURL: "/flow-error?source=oauth&keep=yes"
      }
    )
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")

    status, headers, = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {state: state, error: "access denied/ü", error_description: "User said no & left"},
      as_response: true
    )

    params = Rack::Utils.parse_query(URI.parse(headers.fetch("location")).query)
    assert_equal 302, status
    assert_equal "/flow-error", URI.parse(headers.fetch("location")).path
    assert_equal({"source" => "oauth", "keep" => "yes", "error" => "access denied/ü", "error_description" => "User said no & left"}, params)
  end

  def test_state_cookie_failure_uses_recovered_per_flow_error_url
    auth = build_auth(on_api_error: {error_url: "/fallback-error"})
    _status, _headers, body = auth.call(rack_env(
      "POST",
      "/api/auth/sign-in/oauth2",
      body: {providerId: "custom", callbackURL: "/dashboard", errorCallbackURL: "/flow-error?source=state"}
    ))
    state = Rack::Utils.parse_query(URI.parse(JSON.parse(body.join).fetch("url")).query).fetch("state")

    status, headers, = auth.call(rack_env("GET", "/api/auth/oauth2/callback/custom?code=oauth-code&state=#{URI.encode_www_form_component(state)}"))

    assert_equal 302, status
    assert_equal({"source" => "state", "error" => "state_mismatch"}, Rack::Utils.parse_query(URI.parse(headers.fetch("location")).query))
  end

  def test_callback_redirects_api_error_code_and_message_from_persistence
    auth = build_auth(
      database_hooks: {
        account: {
          update: {
            before: ->(_data, _context) { raise BetterAuth::APIError.new("FORBIDDEN", code: "ACCOUNT_UPDATE_BLOCKED", message: "Account update blocked & audited") }
          }
        }
      }
    )
    first = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard"})
    first_state = Rack::Utils.parse_query(URI.parse(first[:url]).query).fetch("state")
    auth.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: first_state}, as_response: true)

    second = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard", errorCallbackURL: "/error?source=hook"})
    second_state = Rack::Utils.parse_query(URI.parse(second[:url]).query).fetch("state")
    status, headers, = auth.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: second_state}, as_response: true)

    assert_equal 302, status
    assert_equal(
      {"source" => "hook", "error" => "ACCOUNT_UPDATE_BLOCKED", "error_description" => "Account update blocked & audited"},
      Rack::Utils.parse_query(URI.parse(headers.fetch("location")).query)
    )
  end

  def test_callback_redirects_when_provider_and_mapped_profile_omit_email
    auth = build_auth(
      user_info: {id: "missing-email-sub", name: "Missing Email User", emailVerified: true},
      on_api_error: {error_url: "/error"}
    )
    sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard", errorCallbackURL: "/error"})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")

    status, headers, _body = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_includes headers.fetch("location"), "error=email_is_missing"
  end

  def test_callback_redirects_with_missing_user_info_when_custom_get_user_info_returns_nil
    auth = build_auth(
      provider_overrides: {
        get_user_info: ->(_tokens) {}
      },
      on_api_error: {error_url: "/error"}
    )
    sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard", errorCallbackURL: "/error"})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")

    status, headers, = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/error?error=user_info_is_missing", headers.fetch("location")
  end

  def test_additional_data_cannot_override_internal_state_fields
    auth = build_auth(on_api_error: {error_url: "/error"})
    _status, headers, body = auth.api.sign_in_with_oauth2(
      body: {
        providerId: "custom",
        callbackURL: "/dashboard",
        additionalData: {
          callbackURL: "/evil",
          errorURL: "/evil-error",
          codeVerifier: "attacker-verifier"
        }
      },
      as_response: true
    )
    state = Rack::Utils.parse_query(URI.parse(JSON.parse(body.join).fetch("url")).query).fetch("state")

    status, callback_headers, = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/dashboard", callback_headers.fetch("location")
  end

  def test_discovery_headers_are_sent_when_fetching_metadata
    requests = []
    with_oauth_server(requests) do |base_url|
      auth = build_auth(
        provider_overrides: {
          get_token: nil,
          get_user_info: nil,
          authorization_url: nil,
          token_url: nil,
          user_info_url: nil,
          discovery_url: "#{base_url}/.well-known/openid-configuration",
          discovery_headers: {"X-Discovery-Token" => "secret"}
        }
      )

      auth.api.sign_in_with_oauth2(body: {providerId: "custom", disableRedirect: true})

      discovery_request = requests.find { |request| request[:path] == "/.well-known/openid-configuration" }
      assert_equal "secret", discovery_request.fetch(:headers).fetch("x-discovery-token")
    end
  end

  def test_callback_creates_user_account_session_and_redirects_new_user
    auth = build_auth
    sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard", newUserCallbackURL: "/welcome"})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")

    status, headers, _body = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/welcome", headers.fetch("location")
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token="
    user = auth.context.internal_adapter.find_user_by_email("oauth@example.com")[:user]
    account = auth.context.internal_adapter.find_account_by_provider_id("oauth-sub", "custom")
    assert_equal user["id"], account["userId"]
    assert_equal "access-token", account["accessToken"]
    assert_equal "refresh-token", account["refreshToken"]
    assert_equal "openid,email", account["scope"]
  end

  def test_callback_handles_numeric_account_ids_without_duplicate_accounts
    auth = build_auth(user_info: {id: 123_456_789, email: "numeric@example.com", name: "Numeric User", emailVerified: true})

    sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard", newUserCallbackURL: "/welcome"})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")
    status, headers, _body = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/welcome", headers.fetch("location")
    user = auth.context.internal_adapter.find_user_by_email("numeric@example.com")[:user]
    accounts = auth.context.internal_adapter.find_accounts(user["id"])
    assert_equal 1, accounts.length
    assert_equal "123456789", accounts.first["accountId"]

    second_sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard"})
    second_state = Rack::Utils.parse_query(URI.parse(second_sign_in[:url]).query).fetch("state")
    status, headers, _body = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: second_state},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/dashboard", headers.fetch("location")
    assert_equal 1, auth.context.internal_adapter.find_accounts(user["id"]).length
  end

  def test_callback_applies_map_profile_to_user_callable
    auth = build_auth(
      user_info: {id: "mapped-sub", email: "mapped@example.com", name: "Original Name", emailVerified: false},
      provider_overrides: {
        map_profile_to_user: ->(profile) { {name: "Mapped #{profile[:name]}", emailVerified: true} }
      }
    )
    sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard"})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")

    status, _headers, _body = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      as_response: true
    )

    assert_equal 302, status
    user = auth.context.internal_adapter.find_user_by_email("mapped@example.com")[:user]
    assert_equal "Mapped Original Name", user["name"]
    assert_equal true, user["emailVerified"]
  end

  def test_social_provider_get_user_info_applies_map_profile_to_user_callable
    auth = build_auth(
      user_info: {id: "social-provider-sub", email: "social-provider@example.com", name: "Social Provider", emailVerified: true},
      provider_overrides: {
        map_profile_to_user: ->(_profile) { {custom_field: "mapped-data"} }
      }
    )
    provider = auth.context.social_providers.fetch(:custom)

    result = provider.fetch(:get_user_info).call(accessToken: "access-token")

    assert_equal "social-provider@example.com", result.fetch(:user).fetch(:email)
    assert_equal "mapped-data", result.fetch(:user).fetch(:custom_field)
    assert_equal "social-provider-sub", result.fetch(:data).fetch(:id)
  end

  def test_oidc_discovery_provider_helpers_do_not_install_custom_user_info_callbacks
    refute_includes BetterAuth::Plugins.auth0(client_id: "id", client_secret: "secret", domain: "tenant.auth0.com"), :get_user_info
    refute_includes BetterAuth::Plugins.okta(client_id: "id", client_secret: "secret", issuer: "https://okta.example.com/oauth2/default"), :get_user_info
    refute_includes BetterAuth::Plugins.keycloak(client_id: "id", client_secret: "secret", issuer: "https://realm.example.com/realms/main"), :get_user_info
  end

  def test_yandex_helper_fetches_and_maps_profile
    yandex = BetterAuth::Plugins.yandex(client_id: "id", client_secret: "secret")
    profile = {
      "id" => "yandex-id",
      "login" => "fallback-login",
      "display_name" => "Yandex User",
      "default_email" => "yandex@example.com",
      "emails" => ["other@example.com"],
      "is_avatar_empty" => false,
      "default_avatar_id" => "avatar-id"
    }

    with_stubbed_http_json("https://login.yandex.ru/info?format=json" => profile) do |requests|
      assert_equal(
        {
          id: "yandex-id",
          name: "Yandex User",
          email: "yandex@example.com",
          emailVerified: false,
          image: "https://avatars.yandex.net/get-yapic/avatar-id/islands-200"
        },
        yandex.fetch(:get_user_info).call(accessToken: "yandex-token")
      )
      assert_equal ["OAuth yandex-token"], requests.first.fetch(:headers).fetch("authorization")
    end

    profile["display_name"] = nil
    profile["default_email"] = nil
    profile["is_avatar_empty"] = true
    with_stubbed_http_json("https://login.yandex.ru/info?format=json" => profile) do
      result = yandex.fetch(:get_user_info).call(accessToken: "yandex-token")
      assert_equal "fallback-login", result.fetch(:name)
      assert_equal "other@example.com", result.fetch(:email)
      refute_includes result, :image
    end
  end

  def test_access_token_expiry_fallback_applies_to_custom_exchange_without_overwriting_explicit_expiry
    before = Time.now
    auth = build_auth(provider_overrides: {accessTokenExpiresIn: 120})
    sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard"})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")
    auth.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: state}, as_response: true)
    account = auth.context.internal_adapter.find_account_by_provider_id("oauth-sub", "custom")
    assert_operator account.fetch("accessTokenExpiresAt"), :>=, before + 119
    assert_operator account.fetch("accessTokenExpiresAt"), :<=, Time.now + 121

    explicit = Time.now + 600
    auth = build_auth(provider_overrides: {
      access_token_expires_in: 120,
      get_token: ->(**_data) { {accessToken: "explicit-token", accessTokenExpiresAt: explicit} }
    })
    sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard"})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")
    auth.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: state}, as_response: true)
    assert_equal explicit, auth.context.internal_adapter.find_account_by_provider_id("oauth-sub", "custom").fetch("accessTokenExpiresAt")
  end

  def test_access_token_expiry_fallback_applies_to_standard_exchange_and_refresh
    requests = []
    with_oauth_server(requests) do |base_url|
      auth = build_auth(provider_overrides: {
        get_token: nil,
        token_url: "#{base_url}/token",
        token_url_params: {omit_expiry: "1"},
        access_token_expires_in: 120
      })
      before = Time.now
      sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard"})
      state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")
      auth.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: state}, as_response: true)
      account = auth.context.internal_adapter.find_account_by_provider_id("oauth-sub", "custom")
      assert_operator account.fetch("accessTokenExpiresAt"), :>=, before + 119

      refreshed = auth.context.social_providers.fetch(:custom).fetch(:refresh_access_token).call("refresh-token")
      assert_operator refreshed.fetch(:access_token_expires_at), :>=, before + 119
    end
  end

  def test_access_token_expiry_remains_unknown_when_fallback_is_unset_or_nonpositive
    [nil, 0, -1].each do |fallback|
      tokens = BetterAuth::Plugins.send(
        :generic_oauth_normalize_tokens,
        {accessToken: "token"},
        access_token_expires_in: fallback
      )
      refute_includes tokens, :access_token_expires_at
    end
  end

  def test_state_cookie_is_set_and_cleared_for_database_state_strategy
    auth = build_auth
    status, headers, body = auth.api.sign_in_with_oauth2(
      body: {providerId: "custom", callbackURL: "/dashboard"},
      as_response: true
    )
    data = JSON.parse(body.join)
    state = Rack::Utils.parse_query(URI.parse(data.fetch("url")).query).fetch("state")

    assert_equal 200, status
    assert_includes headers.fetch("set-cookie"), "better-auth.state="

    callback_status, callback_headers, = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))},
      as_response: true
    )

    assert_equal 302, callback_status
    state_cookie = callback_headers.fetch("set-cookie").lines.find { |line| line.start_with?("better-auth.state=") }
    assert state_cookie
    assert_includes state_cookie, "Max-Age=0"
  end

  def test_database_state_strategy_rejects_rack_callback_without_state_cookie
    auth = build_auth(on_api_error: {error_url: "/error"})
    _status, _headers, body = auth.call(rack_env("POST", "/api/auth/sign-in/oauth2", body: {providerId: "custom", callbackURL: "/dashboard"}))
    state = Rack::Utils.parse_query(URI.parse(JSON.parse(body.join).fetch("url")).query).fetch("state")

    callback_status, callback_headers, = auth.call(rack_env("GET", "/api/auth/oauth2/callback/custom?code=oauth-code&state=#{URI.encode_www_form_component(state)}"))

    assert_equal 302, callback_status
    assert_equal "/error?error=state_mismatch", callback_headers.fetch("location")
    refute auth.context.internal_adapter.find_account_by_provider_id("oauth-sub", "custom")
  end

  def test_cookie_state_strategy_uses_oauth_state_cookie
    auth = build_auth(account: {store_state_strategy: "cookie"})
    status, headers, body = auth.api.sign_in_with_oauth2(
      body: {providerId: "custom", callbackURL: "/dashboard", newUserCallbackURL: "/welcome"},
      as_response: true
    )
    data = JSON.parse(body.join)
    state = Rack::Utils.parse_query(URI.parse(data.fetch("url")).query).fetch("state")

    assert_equal 200, status
    assert_includes headers.fetch("set-cookie"), "better-auth.oauth_state="

    callback_status, callback_headers, = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))},
      as_response: true
    )

    assert_equal 302, callback_status
    assert_equal "/welcome", callback_headers.fetch("location")
    state_cookie = callback_headers.fetch("set-cookie").lines.find { |line| line.start_with?("better-auth.oauth_state=") }
    assert state_cookie
    assert_includes state_cookie, "Max-Age=0"
  end

  def test_cookie_state_strategy_survives_secret_rotation
    old_auth = build_auth(
      account: {store_state_strategy: "cookie"},
      secrets: [{version: 1, value: "old-generic-oauth-secret-with-enough-entropy"}]
    )
    _status, headers, body = old_auth.api.sign_in_with_oauth2(
      body: {providerId: "custom", callbackURL: "/dashboard", newUserCallbackURL: "/welcome"},
      as_response: true
    )
    state = Rack::Utils.parse_query(URI.parse(JSON.parse(body.join).fetch("url")).query).fetch("state")
    new_auth = build_auth(
      database: old_auth.context.adapter,
      account: {store_state_strategy: "cookie"},
      secrets: [
        {version: 2, value: "new-generic-oauth-secret-with-enough-entropy"},
        {version: 1, value: "old-generic-oauth-secret-with-enough-entropy"}
      ]
    )

    callback_status, callback_headers, = new_auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))},
      as_response: true
    )

    assert_equal 302, callback_status
    assert_equal "/welcome", callback_headers.fetch("location")
  end

  def test_cookie_state_strategy_rejects_state_mismatch
    auth = build_auth(account: {store_state_strategy: "cookie"}, on_api_error: {error_url: "/error"})
    _status, headers, body = auth.api.sign_in_with_oauth2(
      body: {providerId: "custom", callbackURL: "/dashboard"},
      as_response: true
    )
    state = Rack::Utils.parse_query(URI.parse(JSON.parse(body.join).fetch("url")).query).fetch("state")

    callback_status, callback_headers, = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: "#{state}-tampered"},
      headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))},
      as_response: true
    )

    assert_equal 302, callback_status
    assert_equal "/error?error=state_mismatch", callback_headers.fetch("location")
    state_cookie = callback_headers.fetch("set-cookie").lines.find { |line| line.start_with?("better-auth.oauth_state=") }
    assert state_cookie
    assert_includes state_cookie, "Max-Age=0"
  end

  def test_cookie_state_strategy_rejects_missing_state_cookie
    auth = build_auth(account: {store_state_strategy: "cookie"}, on_api_error: {error_url: "/error"})
    _status, _headers, body = auth.api.sign_in_with_oauth2(
      body: {providerId: "custom", callbackURL: "/dashboard"},
      as_response: true
    )
    state = Rack::Utils.parse_query(URI.parse(JSON.parse(body.join).fetch("url")).query).fetch("state")

    callback_status, callback_headers, = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      as_response: true
    )

    assert_equal 302, callback_status
    assert_equal "/error?error=state_mismatch", callback_headers.fetch("location")
  end

  def test_callback_reuses_existing_user_and_honors_disable_implicit_sign_up
    disabled = build_auth(disable_implicit_sign_up: true)
    sign_in = disabled.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard", errorCallbackURL: "/error"})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")
    status, headers, _body = disabled.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: state}, as_response: true)

    assert_equal 302, status
    assert_equal "/error?error=signup_disabled", headers.fetch("location")

    requested = build_auth(disable_implicit_sign_up: true)
    sign_in = requested.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard", errorCallbackURL: "/error", requestSignUp: true})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")
    status, headers, _body = requested.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: state}, as_response: true)

    assert_equal 302, status
    assert_equal "/dashboard", headers.fetch("location")
  end

  def test_override_user_info_updates_existing_user_on_sign_in
    calls = 0
    auth = build_auth(
      provider_overrides: {
        override_user_info: true,
        get_user_info: ->(_tokens) {
          calls += 1
          {
            id: "override-sub",
            email: "override@example.com",
            name: (calls == 1) ? "Original Name" : "Updated Name",
            image: (calls == 1) ? "https://example.com/original.png" : "https://example.com/updated.png",
            emailVerified: true
          }
        }
      }
    )

    first = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard"})
    first_state = Rack::Utils.parse_query(URI.parse(first[:url]).query).fetch("state")
    auth.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: first_state}, as_response: true)

    second = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard"})
    second_state = Rack::Utils.parse_query(URI.parse(second[:url]).query).fetch("state")
    auth.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: second_state}, as_response: true)

    user = auth.context.internal_adapter.find_user_by_email("override@example.com")[:user]
    assert_equal "Updated Name", user.fetch("name")
    assert_equal "https://example.com/updated.png", user.fetch("image")
  end

  def test_callback_rejects_implicit_link_to_unverified_local_user_by_default
    auth = build_auth(user_info: {id: "implicit-sub", email: "implicit@example.com", name: "Remote", emailVerified: true})
    sign_up_cookie(auth, email: "implicit@example.com")
    user = auth.context.internal_adapter.find_user_by_email("implicit@example.com")[:user]
    old_session_tokens = auth.context.internal_adapter.list_sessions(user["id"]).map { |session| session["token"] }
    sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard", errorCallbackURL: "/error"})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")

    status, headers, = auth.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: state}, as_response: true)

    assert_equal 302, status
    assert_equal "/error?error=account_not_linked", headers.fetch("location")
    assert_nil auth.context.internal_adapter.find_account_by_provider_id("implicit-sub", "custom")
    assert_equal old_session_tokens, auth.context.internal_adapter.list_sessions(user["id"]).map { |session| session["token"] }
    refute auth.context.internal_adapter.find_user_by_id(user["id"])["emailVerified"]
  end

  def test_callback_implicitly_links_verified_local_user
    auth = build_auth(user_info: {id: "verified-local-sub", email: "verified-local-oauth@example.com", name: "Remote", emailVerified: true})
    sign_up_cookie(auth, email: "verified-local-oauth@example.com")
    user = auth.context.internal_adapter.find_user_by_email("verified-local-oauth@example.com")[:user]
    auth.context.internal_adapter.update_user(user["id"], emailVerified: true)
    sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard"})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")

    status, headers, = auth.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: state}, as_response: true)

    assert_equal 302, status
    assert_equal "/dashboard", headers.fetch("location")
    assert auth.context.internal_adapter.find_account_by_provider_id("verified-local-sub", "custom")
  end

  def test_callback_require_local_email_verified_opt_out_supports_snake_and_camel_case
    [
      {account: {account_linking: {require_local_email_verified: false}}},
      {account: {accountLinking: {requireLocalEmailVerified: false}}}
    ].each_with_index do |linking_options, index|
      email = "generic-opt-out-#{index}@example.com"
      account_id = "generic-opt-out-#{index}"
      auth = build_auth(linking_options.merge(user_info: {id: account_id, email: email, name: "Opt Out", emailVerified: true}))
      sign_up_cookie(auth, email: email)
      sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard"})
      state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")

      status, = auth.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: state}, as_response: true)

      assert_equal 302, status
      assert auth.context.internal_adapter.find_account_by_provider_id(account_id, "custom")
      assert auth.context.internal_adapter.find_user_by_email(email)[:user]["emailVerified"]
    end
  end

  def test_callback_rolls_back_implicit_link_when_verified_email_promotion_is_vetoed
    auth = build_auth(
      account: {account_linking: {require_local_email_verified: false}},
      database_hooks: {
        user: {
          update: {
            before: ->(data, _context) { false if data["emailVerified"] == true }
          }
        }
      },
      user_info: {id: "generic-promotion-veto", email: "generic-promotion-veto@example.com", name: "Veto", emailVerified: true}
    )
    sign_up_cookie(auth, email: "generic-promotion-veto@example.com")
    user = auth.context.internal_adapter.find_user_by_email("generic-promotion-veto@example.com").fetch(:user)
    session_count = auth.context.internal_adapter.list_sessions(user.fetch("id")).length
    sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard"})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")

    assert_raises(BetterAuth::Error) do
      auth.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: state}, as_response: true)
    end

    assert_nil auth.context.internal_adapter.find_account_by_provider_id("generic-promotion-veto", "custom")
    refute auth.context.internal_adapter.find_user_by_id(user.fetch("id")).fetch("emailVerified")
    assert_equal session_count, auth.context.internal_adapter.list_sessions(user.fetch("id")).length
  end

  def test_override_user_info_failure_links_account_without_creating_session
    auth = build_auth(
      database_hooks: {
        user: {
          update: {
            before: lambda do |data, _context|
              raise "override storage failed" if data["name"] == "Override Failure"
            end
          }
        }
      },
      user_info: {
        id: "override-failure-sub",
        email: "override-failure@example.com",
        name: "Override Failure",
        emailVerified: true
      },
      provider_overrides: {override_user_info: true}
    )
    sign_up_cookie(auth, email: "override-failure@example.com")
    user = auth.context.internal_adapter.find_user_by_email("override-failure@example.com").fetch(:user)
    auth.context.internal_adapter.update_user(user.fetch("id"), emailVerified: true)
    session_tokens = auth.context.internal_adapter.list_sessions(user.fetch("id")).map { |session| session.fetch("token") }
    sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard"})
    state = Rack::Utils.parse_query(URI.parse(sign_in.fetch(:url)).query).fetch("state")

    error = assert_raises(RuntimeError) do
      auth.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: state}, as_response: true)
    end

    assert_equal "override storage failed", error.message
    assert auth.context.internal_adapter.find_account_by_provider_id("override-failure-sub", "custom")
    assert_equal session_tokens, auth.context.internal_adapter.list_sessions(user.fetch("id")).map { |session| session.fetch("token") }
  end

  def test_override_user_info_veto_links_account_without_creating_session
    auth = build_auth(
      database_hooks: {
        user: {
          update: {
            before: ->(data, _context) { false if data["name"] == "Override Veto" }
          }
        }
      },
      user_info: {
        id: "override-veto-sub",
        email: "override-veto@example.com",
        name: "Override Veto",
        emailVerified: true
      },
      provider_overrides: {override_user_info: true}
    )
    sign_up_cookie(auth, email: "override-veto@example.com")
    user = auth.context.internal_adapter.find_user_by_email("override-veto@example.com").fetch(:user)
    auth.context.internal_adapter.update_user(user.fetch("id"), emailVerified: true)
    session_tokens = auth.context.internal_adapter.list_sessions(user.fetch("id")).map { |session| session.fetch("token") }
    sign_in = auth.api.sign_in_with_oauth2(body: {
      providerId: "custom",
      callbackURL: "/dashboard",
      errorCallbackURL: "/error"
    })
    state = Rack::Utils.parse_query(URI.parse(sign_in.fetch(:url)).query).fetch("state")

    status, headers, = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/error?error=unable_to_create_user", headers.fetch("location")
    assert auth.context.internal_adapter.find_account_by_provider_id("override-veto-sub", "custom")
    assert_equal session_tokens, auth.context.internal_adapter.list_sessions(user.fetch("id")).map { |session| session.fetch("token") }
  end

  def test_override_user_info_cannot_pre_promote_unverified_local_user_past_gate
    auth = build_auth(
      user_info: {id: "override-bypass-sub", email: "override-bypass@example.com", name: "Remote Name", emailVerified: true},
      provider_overrides: {override_user_info: true}
    )
    sign_up_cookie(auth, email: "override-bypass@example.com")
    user = auth.context.internal_adapter.find_user_by_email("override-bypass@example.com")[:user]
    old_session_tokens = auth.context.internal_adapter.list_sessions(user["id"]).map { |session| session["token"] }
    sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard", errorCallbackURL: "/error"})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")

    status, headers, = auth.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: state}, as_response: true)

    stored = auth.context.internal_adapter.find_user_by_id(user["id"])
    assert_equal 302, status
    assert_equal "/error?error=account_not_linked", headers.fetch("location")
    assert_equal "OAuth User", stored["name"]
    refute stored["emailVerified"]
    assert_nil auth.context.internal_adapter.find_account_by_provider_id("override-bypass-sub", "custom")
    assert_equal old_session_tokens, auth.context.internal_adapter.list_sessions(user["id"]).map { |session| session["token"] }
  end

  def test_callback_disable_implicit_linking_blocks_existing_user_but_allows_new_user
    profile = {id: "blocked-generic", email: "blocked-generic@example.com", name: "Blocked", emailVerified: true}
    auth = build_auth(account: {account_linking: {disable_implicit_linking: true}}, provider_overrides: {get_user_info: ->(_tokens) { profile }})
    sign_up_cookie(auth, email: profile[:email])
    sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard", errorCallbackURL: "/error"})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")

    _status, headers, = auth.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: state}, as_response: true)
    assert_equal "/error?error=account_not_linked", headers.fetch("location")

    profile[:id] = "new-generic"
    profile[:email] = "new-generic@example.com"
    new_sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard"})
    new_state = Rack::Utils.parse_query(URI.parse(new_sign_in[:url]).query).fetch("state")
    _status, headers, = auth.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: new_state}, as_response: true)

    assert_equal "/dashboard", headers.fetch("location")
    assert auth.context.internal_adapter.find_account_by_provider_id("new-generic", "custom")
  end

  def test_callback_rejects_blank_remote_id_for_implicit_and_explicit_flows
    [false, true].each do |explicit|
      email = explicit ? "blank-explicit@example.com" : "blank-implicit@example.com"
      auth = build_auth(user_info: {id: "  ", email: email, name: "Blank", emailVerified: true})
      cookie = explicit ? sign_up_cookie(auth, email: email) : nil
      start = if explicit
        auth.api.oauth2_link_account(headers: {"cookie" => cookie}, body: {providerId: "custom", callbackURL: "/settings", errorCallbackURL: "/error"})
      else
        auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard", errorCallbackURL: "/error"})
      end
      state = Rack::Utils.parse_query(URI.parse(start[:url]).query).fetch("state")
      existing_sessions = auth.context.internal_adapter.adapter.find_many(model: "session").length

      status, headers, = auth.api.oauth2_callback(params: {providerId: "custom"}, query: {code: "oauth-code", state: state}, as_response: true)

      assert_equal 302, status
      assert_equal "/error?error=user_info_is_missing", headers.fetch("location")
      assert_empty auth.context.internal_adapter.adapter.find_many(model: "account").select { |account| account["accountId"].to_s.strip.empty? }
      assert_equal existing_sessions, auth.context.internal_adapter.adapter.find_many(model: "session").length
    end
  end

  def test_link_account_generates_link_state_and_callback_links_to_current_user
    auth = build_auth(user_info: {id: "linked-sub", email: "link@example.com", name: "Linked User"})
    cookie = sign_up_cookie(auth, email: "link@example.com")
    link = auth.api.oauth2_link_account(
      headers: {"cookie" => cookie},
      body: {providerId: "custom", callbackURL: "/settings", scopes: ["files"]}
    )
    state = Rack::Utils.parse_query(URI.parse(link[:url]).query).fetch("state")

    status, headers, _body = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/settings", headers.fetch("location")
    user = auth.context.internal_adapter.find_user_by_email("link@example.com")[:user]
    account = auth.context.internal_adapter.find_account_by_provider_id("linked-sub", "custom")
    assert_equal user["id"], account["userId"]
  end

  def test_invalid_provider_and_issuer_mismatch_errors
    auth = build_auth

    provider_error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_with_oauth2(body: {providerId: "missing"})
    end
    assert_equal 400, provider_error.status_code
    assert_equal "No config found for provider missing", provider_error.message

    sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", errorCallbackURL: "/error"})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")
    status, headers, _body = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state, iss: "https://wrong.example.com"},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/error?error=issuer_mismatch", headers.fetch("location")
  end

  def test_callback_redirects_when_custom_get_token_raises
    auth = build_auth(
      provider_overrides: {
        get_token: ->(**_data) { raise "provider down" }
      }
    )
    status, headers, body = auth.api.sign_in_with_oauth2(
      body: {providerId: "custom", errorCallbackURL: "/error"},
      as_response: true
    )
    state = Rack::Utils.parse_query(URI.parse(JSON.parse(body.join).fetch("url")).query).fetch("state")

    callback_status, callback_headers, = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))},
      as_response: true
    )

    assert_equal 200, status
    assert_equal 302, callback_status
    assert_equal "/error?error=oauth_code_verification_failed", callback_headers.fetch("location")
  end

  def test_standard_http_token_exchange_supports_headers_basic_auth_params_and_userinfo_mapping
    requests = []
    with_oauth_server(requests) do |base_url|
      auth = build_auth(
        provider_overrides: {
          get_token: nil,
          get_user_info: nil,
          authorization_url: "#{base_url}/authorize",
          token_url: "#{base_url}/token",
          user_info_url: "#{base_url}/userinfo",
          authorization_headers: {"X-Custom-Header" => "test-value"},
          token_url_params: ->(_ctx) { {audience: "api", resource: "calendar"} },
          authentication: "basic",
          pkce: true
        }
      )
      status, headers, body = auth.api.sign_in_with_oauth2(
        body: {providerId: "custom", callbackURL: "/dashboard"},
        as_response: true
      )
      state = Rack::Utils.parse_query(URI.parse(JSON.parse(body.join).fetch("url")).query).fetch("state")

      callback_status, callback_headers, = auth.api.oauth2_callback(
        params: {providerId: "custom"},
        query: {code: "oauth-code", state: state},
        headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))},
        as_response: true
      )

      assert_equal 200, status
      assert_equal 302, callback_status
      assert_equal "/dashboard", callback_headers.fetch("location")
      token_request = requests.find { |request| request[:path] == "/token" }
      assert token_request
      assert_equal "POST", token_request.fetch(:method)
      assert_equal "test-value", token_request.fetch(:headers).fetch("x-custom-header")
      assert_match(/\ABasic /, token_request.fetch(:headers).fetch("authorization"))
      assert_equal "oauth-code", token_request.fetch(:params).fetch("code")
      assert_equal "api", token_request.fetch(:params).fetch("audience")
      assert_equal "calendar", token_request.fetch(:params).fetch("resource")
      refute token_request.fetch(:params).key?("client_secret")

      userinfo_request = requests.find { |request| request[:path] == "/userinfo" }
      assert_equal "Bearer http-access-token", userinfo_request.fetch(:headers).fetch("authorization")
      account = auth.context.internal_adapter.find_account_by_provider_id("http-sub", "custom")
      assert_equal "http-access-token", account.fetch("accessToken")
      assert_equal "http-refresh-token", account.fetch("refreshToken")
      assert_equal "openid,email", account.fetch("scope")
      assert_instance_of Time, account.fetch("accessTokenExpiresAt")
      assert_instance_of Time, account.fetch("refreshTokenExpiresAt")
    end
  end

  def test_generic_oauth_id_token_user_info_requires_sub_and_email_before_skipping_userinfo
    requests = []
    with_oauth_server(requests) do |base_url|
      [
        {"sub" => "token-sub", "name" => "Token Only"},
        {"sub" => "token-sub", "email" => "", "name" => "Blank Email"},
        {"sub" => "", "email" => "token@example.com", "name" => "Blank Subject"}
      ].each do |payload|
        requests.clear
        auth = build_auth(
          provider_overrides: {
            get_token: ->(**_data) {
              {
                accessToken: "http-access-token",
                refreshToken: "http-refresh-token",
                idToken: unsigned_jwt(payload),
                scopes: ["openid", "email"]
              }
            },
            get_user_info: nil,
            authorization_url: "#{base_url}/authorize",
            token_url: "#{base_url}/token",
            user_info_url: "#{base_url}/userinfo"
          }
        )
        sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard"})
        state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")

        status, headers, = auth.api.oauth2_callback(
          params: {providerId: "custom"},
          query: {code: "oauth-code", state: state},
          as_response: true
        )

        assert_equal 302, status
        assert_equal "/dashboard", headers.fetch("location")
        assert requests.find { |request| request[:path] == "/userinfo" }, "expected userinfo fallback for #{payload.inspect}"
        assert auth.context.internal_adapter.find_account_by_provider_id("http-sub", "custom")
      end
    end

    auth = build_auth(
      provider_overrides: {
        get_token: ->(**_data) {
          {
            accessToken: "access-token",
            idToken: unsigned_jwt("sub" => "token-sub", "name" => "Token Only")
          }
        },
        get_user_info: nil,
        user_info_url: nil
      },
      on_api_error: {error_url: "/error"}
    )
    sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard"})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")

    status, headers, = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "http://localhost:3000/api/auth/error?error=user_info_is_missing", headers.fetch("location")
  end

  def test_provider_helper_factories_match_upstream_defaults
    helper_expectations.each do |entry|
      config = BetterAuth::Plugins.public_send(entry.fetch(:helper), **entry.fetch(:options))

      entry.fetch(:defaults).each do |key, value|
        assert_equal value, config[key], "#{entry.fetch(:helper)} #{key}"
      end
      assert_equal "id", config.fetch(:client_id), "#{entry.fetch(:helper)} client_id"
      assert_equal "secret", config.fetch(:client_secret), "#{entry.fetch(:helper)} client_secret"
      assert_equal entry.fetch(:has_get_user_info), config.key?(:get_user_info), "#{entry.fetch(:helper)} get_user_info presence"
    end
  end

  def test_provider_helper_factories_preserve_overrides_and_camel_case_inputs
    helper_override_expectations.each do |entry|
      config = BetterAuth::Plugins.public_send(entry.fetch(:helper), **entry.fetch(:options))

      assert_equal ["custom.scope"], config.fetch(:scopes), "#{entry.fetch(:helper)} scopes"
      assert_equal "https://app.example.com/callback", config.fetch(:redirect_uri), "#{entry.fetch(:helper)} redirect_uri"
      assert_equal true, config.fetch(:pkce), "#{entry.fetch(:helper)} pkce"
      assert_equal true, config.fetch(:disable_implicit_sign_up), "#{entry.fetch(:helper)} disable_implicit_sign_up"
      assert_equal true, config.fetch(:disable_sign_up), "#{entry.fetch(:helper)} disable_sign_up"
      assert_equal true, config.fetch(:override_user_info), "#{entry.fetch(:helper)} override_user_info"
      entry.fetch(:expected).each do |key, value|
        assert_equal value, config[key], "#{entry.fetch(:helper)} #{key}"
      end
    end
  end

  def test_custom_provider_helpers_map_user_info_like_upstream
    gumroad = BetterAuth::Plugins.gumroad(client_id: "id", client_secret: "secret")
    with_stubbed_http_json("https://api.gumroad.com/v2/user" => {"success" => false}) do
      assert_nil gumroad.fetch(:get_user_info).call(accessToken: "token")
    end
    with_stubbed_http_json("https://api.gumroad.com/v2/user" => {"success" => true}) do
      assert_nil gumroad.fetch(:get_user_info).call(accessToken: "token")
    end
    with_stubbed_http_json("https://api.gumroad.com/v2/user" => {"success" => true, "user" => {"user_id" => "gumroad-id", "name" => "Gumroad User", "email" => "gumroad@example.com", "profile_url" => "https://img.example.com/gumroad.png"}}) do
      assert_equal(
        {id: "gumroad-id", name: "Gumroad User", email: "gumroad@example.com", image: "https://img.example.com/gumroad.png", emailVerified: false},
        gumroad.fetch(:get_user_info).call(accessToken: "token")
      )
    end

    hubspot = BetterAuth::Plugins.hubspot(client_id: "id", client_secret: "secret")
    with_stubbed_http_json("https://api.hubapi.com/oauth/v1/access-tokens/token" => {"user" => "hubspot@example.com"}) do
      assert_nil hubspot.fetch(:get_user_info).call(accessToken: "token")
    end
    with_stubbed_http_json("https://api.hubapi.com/oauth/v1/access-tokens/token" => {"user" => "hubspot@example.com", "signed_access_token" => {"userId" => "hubspot-signed-id"}}) do
      assert_equal(
        {id: "hubspot-signed-id", name: "hubspot@example.com", email: "hubspot@example.com", emailVerified: false},
        hubspot.fetch(:get_user_info).call(accessToken: "token")
      )
    end
    with_stubbed_http_json("https://api.hubapi.com/oauth/v1/access-tokens/token" => {"user_id" => "hubspot-id", "user" => "hubspot@example.com"}) do
      result = hubspot.fetch(:get_user_info).call(accessToken: "token")
      assert_equal "hubspot-id", result.fetch(:id)
      refute_includes result, :image
    end

    line = BetterAuth::Plugins.line(provider_id: "line-th", client_id: "id", client_secret: "secret")
    assert_equal "line-th", line.fetch(:provider_id)
    require "better_auth/plugins/jwt"
    id_token_profile = line.fetch(:get_user_info).call(idToken: unsigned_jwt("sub" => "line-token-id", "name" => "Line Token", "email" => "line-token@example.com", "picture" => "https://img.example.com/line-token.png"), accessToken: "token")
    assert_equal({id: "line-token-id", name: "Line Token", email: "line-token@example.com", image: "https://img.example.com/line-token.png", emailVerified: false}, id_token_profile)
    with_stubbed_http_json("https://api.line.me/oauth2/v2.1/userinfo" => {"sub" => "line-http-id", "name" => "Line HTTP", "email" => "line-http@example.com", "picture" => "https://img.example.com/line-http.png"}) do
      assert_equal({id: "line-http-id", name: "Line HTTP", email: "line-http@example.com", image: "https://img.example.com/line-http.png", emailVerified: false}, line.fetch(:get_user_info).call(idToken: "bad-token", accessToken: "token"))
    end

    microsoft = BetterAuth::Plugins.microsoft_entra_id(client_id: "id", client_secret: "secret", tenant_id: "common")
    with_stubbed_http_json("https://graph.microsoft.com/oidc/userinfo" => {"sub" => "ms-id", "given_name" => "Microsoft", "family_name" => "User", "preferred_username" => "microsoft@example.com", "picture" => "https://img.example.com/ms.png"}) do
      assert_equal({id: "ms-id", name: "Microsoft User", email: "microsoft@example.com", image: "https://img.example.com/ms.png", emailVerified: false}, microsoft.fetch(:get_user_info).call(accessToken: "token"))
    end

    patreon = BetterAuth::Plugins.patreon(client_id: "id", client_secret: "secret")
    with_stubbed_http_json("https://www.patreon.com/api/oauth2/v2/identity?fields[user]=email,full_name,image_url,is_email_verified" => {"data" => {"id" => "patreon-id"}}) do
      assert_nil patreon.fetch(:get_user_info).call(accessToken: "token")
    end
    with_stubbed_http_json("https://www.patreon.com/api/oauth2/v2/identity?fields[user]=email,full_name,image_url,is_email_verified" => {"data" => {"id" => "patreon-id", "attributes" => {"full_name" => "Patreon User", "email" => "patreon@example.com", "image_url" => "https://img.example.com/patreon.png", "is_email_verified" => true}}}) do
      assert_equal({id: "patreon-id", name: "Patreon User", email: "patreon@example.com", image: "https://img.example.com/patreon.png", emailVerified: true}, patreon.fetch(:get_user_info).call(accessToken: "token"))
    end

    slack = BetterAuth::Plugins.slack(client_id: "id", client_secret: "secret")
    with_stubbed_http_json("https://slack.com/api/openid.connect.userInfo" => {"sub" => "slack-sub", "https://slack.com/user_id" => "slack-id", "name" => "Slack User", "email" => "slack@example.com", "https://slack.com/user_image_512" => "https://img.example.com/slack.png"}) do
      assert_equal({id: "slack-id", name: "Slack User", email: "slack@example.com", image: "https://img.example.com/slack.png", emailVerified: false}, slack.fetch(:get_user_info).call(accessToken: "token"))
    end
  end

  def test_duplicate_provider_ids_emit_warning
    _out, err = capture_io do
      BetterAuth::Plugins.generic_oauth(
        config: [
          {provider_id: "dup", client_id: "id", client_secret: "secret", authorization_url: "https://one.example/auth", token_url: "https://one.example/token"},
          {provider_id: "dup", client_id: "id", client_secret: "secret", authorization_url: "https://two.example/auth", token_url: "https://two.example/token"}
        ]
      )
    end

    assert_includes err, "Duplicate provider IDs found: dup"
  end

  def test_generic_oauth_provider_is_available_to_account_info
    auth = build_auth(user_info: {id: "info-sub", email: "info@example.com", name: "Info User", emailVerified: true})
    sign_in = auth.api.sign_in_with_oauth2(body: {providerId: "custom", callbackURL: "/dashboard"})
    state = Rack::Utils.parse_query(URI.parse(sign_in[:url]).query).fetch("state")
    _status, headers, = auth.api.oauth2_callback(
      params: {providerId: "custom"},
      query: {code: "oauth-code", state: state},
      as_response: true
    )
    account = auth.context.internal_adapter.find_account_by_provider_id("info-sub", "custom")

    info = auth.api.account_info(
      headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))},
      query: {accountId: account.fetch("accountId")}
    )

    assert_equal "info-sub", info.fetch(:user).fetch(:id)
    assert_equal "info@example.com", info.fetch(:user).fetch(:email)
    assert_equal "info-sub", info.fetch(:data).fetch(:id)
  end

  def test_generic_oauth_provider_refreshes_access_tokens_through_account_routes
    requests = []
    with_oauth_server(requests) do |base_url|
      auth = build_auth(
        provider_overrides: {
          get_token: nil,
          get_user_info: nil,
          authorization_url: "#{base_url}/authorize",
          token_url: "#{base_url}/token",
          user_info_url: "#{base_url}/userinfo",
          authentication: "basic",
          token_url_params: ->(_ctx) { {resource: "calendar"} }
        }
      )
      _status, sign_in_headers, sign_in_body = auth.api.sign_in_with_oauth2(
        body: {providerId: "custom", callbackURL: "/dashboard"},
        as_response: true
      )
      state = Rack::Utils.parse_query(URI.parse(JSON.parse(sign_in_body.join).fetch("url")).query).fetch("state")
      _callback_status, callback_headers, = auth.api.oauth2_callback(
        params: {providerId: "custom"},
        query: {code: "oauth-code", state: state},
        headers: {"cookie" => cookie_header(sign_in_headers.fetch("set-cookie"))},
        as_response: true
      )
      account = auth.context.internal_adapter.find_account_by_provider_id("http-sub", "custom")
      auth.context.internal_adapter.update_account(account.fetch("id"), "accessTokenExpiresAt" => Time.now - 60)

      token = auth.api.get_access_token(
        headers: {"cookie" => cookie_header(callback_headers.fetch("set-cookie"))},
        body: {providerId: "custom"}
      )

      assert_equal "refreshed-access-token", token.fetch(:accessToken)
      refresh_request = requests.reverse.find { |request| request[:path] == "/token" }
      assert_equal "refresh_token", refresh_request.fetch(:params).fetch("grant_type")
      assert_equal "http-refresh-token", refresh_request.fetch(:params).fetch("refresh_token")
      assert_equal "calendar", refresh_request.fetch(:params).fetch("resource")
      assert_match(/\ABasic /, refresh_request.fetch(:headers).fetch("authorization"))
    end
  end

  def test_generic_oauth_sets_and_refreshes_account_cookie
    requests = []
    with_oauth_server(requests) do |base_url|
      auth = build_auth(
        account: {store_account_cookie: true},
        provider_overrides: {
          get_token: nil,
          get_user_info: nil,
          authorization_url: "#{base_url}/authorize",
          token_url: "#{base_url}/token",
          user_info_url: "#{base_url}/userinfo"
        }
      )
      _status, sign_in_headers, sign_in_body = auth.api.sign_in_with_oauth2(
        body: {providerId: "custom", callbackURL: "/dashboard"},
        as_response: true
      )
      state = Rack::Utils.parse_query(URI.parse(JSON.parse(sign_in_body.join).fetch("url")).query).fetch("state")
      _callback_status, callback_headers, = auth.api.oauth2_callback(
        params: {providerId: "custom"},
        query: {code: "oauth-code", state: state},
        headers: {"cookie" => cookie_header(sign_in_headers.fetch("set-cookie"))},
        as_response: true
      )
      account_cookie = decoded_account_cookie(callback_headers.fetch("set-cookie"), auth)

      assert_equal "custom", account_cookie.fetch("providerId")
      assert_equal "http-sub", account_cookie.fetch("accountId")
      assert_equal "http-access-token", account_cookie.fetch("accessToken")

      _token_status, token_headers, = auth.api.refresh_token(
        headers: {"cookie" => cookie_header(callback_headers.fetch("set-cookie"))},
        body: {providerId: "custom"},
        as_response: true
      )
      refreshed_cookie = decoded_account_cookie(token_headers.fetch("set-cookie"), auth)

      assert_equal "refreshed-access-token", refreshed_cookie.fetch("accessToken")
      assert_equal "http-refresh-token", refreshed_cookie.fetch("refreshToken")
    end
  end

  def test_account_routes_can_read_generic_oauth_account_cookie
    requests = []
    with_oauth_server(requests) do |base_url|
      auth = build_auth(
        account: {store_account_cookie: true},
        provider_overrides: {
          get_token: nil,
          get_user_info: nil,
          authorization_url: "#{base_url}/authorize",
          token_url: "#{base_url}/token",
          user_info_url: "#{base_url}/userinfo"
        }
      )
      _status, sign_in_headers, sign_in_body = auth.api.sign_in_with_oauth2(
        body: {providerId: "custom", callbackURL: "/dashboard"},
        as_response: true
      )
      state = Rack::Utils.parse_query(URI.parse(JSON.parse(sign_in_body.join).fetch("url")).query).fetch("state")
      _callback_status, callback_headers, = auth.api.oauth2_callback(
        params: {providerId: "custom"},
        query: {code: "oauth-code", state: state},
        headers: {"cookie" => cookie_header(sign_in_headers.fetch("set-cookie"))},
        as_response: true
      )
      account = auth.context.internal_adapter.find_account_by_provider_id("http-sub", "custom")
      auth.context.internal_adapter.delete_account(account.fetch("id"))

      token = auth.api.get_access_token(
        headers: {"cookie" => cookie_header(callback_headers.fetch("set-cookie"))},
        body: {providerId: "custom"}
      )

      assert_equal "http-access-token", token.fetch(:accessToken)
      assert_equal ["openid", "email"], token.fetch(:scopes)
    end
  end

  def test_generic_oauth_encrypts_stored_tokens_and_returns_decrypted_access_token
    requests = []
    with_oauth_server(requests) do |base_url|
      auth = build_auth(
        account: {store_account_cookie: true, encrypt_oauth_tokens: true},
        provider_overrides: {
          get_token: nil,
          get_user_info: nil,
          authorization_url: "#{base_url}/authorize",
          token_url: "#{base_url}/token",
          user_info_url: "#{base_url}/userinfo"
        }
      )
      _status, sign_in_headers, sign_in_body = auth.api.sign_in_with_oauth2(
        body: {providerId: "custom", callbackURL: "/dashboard"},
        as_response: true
      )
      state = Rack::Utils.parse_query(URI.parse(JSON.parse(sign_in_body.join).fetch("url")).query).fetch("state")
      _callback_status, callback_headers, = auth.api.oauth2_callback(
        params: {providerId: "custom"},
        query: {code: "oauth-code", state: state},
        headers: {"cookie" => cookie_header(sign_in_headers.fetch("set-cookie"))},
        as_response: true
      )
      account = auth.context.internal_adapter.find_account_by_provider_id("http-sub", "custom")
      account_cookie = decoded_account_cookie(callback_headers.fetch("set-cookie"), auth)

      refute_equal "http-access-token", account.fetch("accessToken")
      refute_equal "http-refresh-token", account.fetch("refreshToken")
      refute_equal "http-access-token", account_cookie.fetch("accessToken")

      token = auth.api.get_access_token(
        headers: {"cookie" => cookie_header(callback_headers.fetch("set-cookie"))},
        body: {providerId: "custom"}
      )

      assert_equal "http-access-token", token.fetch(:accessToken)

      auth.context.internal_adapter.update_account(account.fetch("id"), "accessTokenExpiresAt" => Time.now - 60)
      refreshed = auth.api.get_access_token(
        headers: {"cookie" => cookie_header_without_account_data(callback_headers.fetch("set-cookie"), auth)},
        body: {providerId: "custom"}
      )

      assert_equal "refreshed-access-token", refreshed.fetch(:accessToken)
    end
  end

  private

  def helper_expectations
    [
      {
        helper: :auth0,
        options: {clientId: "id", clientSecret: "secret", domain: "https://tenant.auth0.com"},
        defaults: {provider_id: "auth0", discovery_url: "https://tenant.auth0.com/.well-known/openid-configuration", scopes: ["openid", "profile", "email"]},
        has_get_user_info: false
      },
      {
        helper: :gumroad,
        options: {client_id: "id", client_secret: "secret"},
        defaults: {provider_id: "gumroad", authorization_url: "https://gumroad.com/oauth/authorize", token_url: "https://api.gumroad.com/oauth/token", scopes: ["view_profile"]},
        has_get_user_info: true
      },
      {
        helper: :hubspot,
        options: {client_id: "id", client_secret: "secret"},
        defaults: {provider_id: "hubspot", authorization_url: "https://app.hubspot.com/oauth/authorize", token_url: "https://api.hubapi.com/oauth/v1/token", scopes: ["oauth"], authentication: "post"},
        has_get_user_info: true
      },
      {
        helper: :keycloak,
        options: {client_id: "id", client_secret: "secret", issuer: "https://realm.example.com/realms/main/"},
        defaults: {provider_id: "keycloak", discovery_url: "https://realm.example.com/realms/main/.well-known/openid-configuration", scopes: ["openid", "profile", "email"]},
        has_get_user_info: false
      },
      {
        helper: :line,
        options: {providerId: "line-jp", client_id: "id", client_secret: "secret"},
        defaults: {provider_id: "line-jp", authorization_url: "https://access.line.me/oauth2/v2.1/authorize", token_url: "https://api.line.me/oauth2/v2.1/token", user_info_url: "https://api.line.me/oauth2/v2.1/userinfo", scopes: ["openid", "profile", "email"]},
        has_get_user_info: true
      },
      {
        helper: :microsoft_entra_id,
        options: {client_id: "id", client_secret: "secret", tenantId: "common"},
        defaults: {provider_id: "microsoft-entra-id", authorization_url: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize", token_url: "https://login.microsoftonline.com/common/oauth2/v2.0/token", user_info_url: "https://graph.microsoft.com/oidc/userinfo", scopes: ["openid", "profile", "email"]},
        has_get_user_info: true
      },
      {
        helper: :okta,
        options: {client_id: "id", client_secret: "secret", issuer: "https://okta.example.com/oauth2/default/"},
        defaults: {provider_id: "okta", discovery_url: "https://okta.example.com/oauth2/default/.well-known/openid-configuration", scopes: ["openid", "profile", "email"]},
        has_get_user_info: false
      },
      {
        helper: :patreon,
        options: {client_id: "id", client_secret: "secret"},
        defaults: {provider_id: "patreon", authorization_url: "https://www.patreon.com/oauth2/authorize", token_url: "https://www.patreon.com/api/oauth2/token", scopes: ["identity[email]"]},
        has_get_user_info: true
      },
      {
        helper: :slack,
        options: {client_id: "id", client_secret: "secret"},
        defaults: {provider_id: "slack", authorization_url: "https://slack.com/openid/connect/authorize", token_url: "https://slack.com/api/openid.connect.token", user_info_url: "https://slack.com/api/openid.connect.userInfo", scopes: ["openid", "profile", "email"]},
        has_get_user_info: true
      },
      {
        helper: :yandex,
        options: {client_id: "id", client_secret: "secret"},
        defaults: {provider_id: "yandex", authorization_url: "https://oauth.yandex.com/authorize", token_url: "https://oauth.yandex.com/token", scopes: ["login:info", "login:email", "login:avatar"]},
        has_get_user_info: true
      }
    ]
  end

  def helper_override_expectations
    base = {
      client_id: "id",
      client_secret: "secret",
      scopes: ["custom.scope"],
      redirect_uri: "https://app.example.com/callback",
      pkce: true,
      disable_implicit_sign_up: true,
      disable_sign_up: true,
      override_user_info: true
    }
    camel_base = {
      clientId: "id",
      clientSecret: "secret",
      scopes: ["custom.scope"],
      redirectURI: "https://app.example.com/callback",
      pkce: true,
      disableImplicitSignUp: true,
      disableSignUp: true,
      overrideUserInfo: true
    }

    [
      {helper: :auth0, options: camel_base.merge(domain: "https://tenant.auth0.com"), expected: {discovery_url: "https://tenant.auth0.com/.well-known/openid-configuration"}},
      {helper: :gumroad, options: base, expected: {}},
      {helper: :hubspot, options: base, expected: {authentication: "post"}},
      {helper: :keycloak, options: base.merge(issuer: "https://realm.example.com/realms/main/"), expected: {discovery_url: "https://realm.example.com/realms/main/.well-known/openid-configuration"}},
      {helper: :line, options: camel_base.merge(providerId: "line-th"), expected: {provider_id: "line-th"}},
      {helper: :microsoft_entra_id, options: camel_base.merge(tenantId: "organizations"), expected: {authorization_url: "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize", token_url: "https://login.microsoftonline.com/organizations/oauth2/v2.0/token"}},
      {helper: :okta, options: base.merge(issuer: "https://okta.example.com/oauth2/default/"), expected: {discovery_url: "https://okta.example.com/oauth2/default/.well-known/openid-configuration"}},
      {helper: :patreon, options: base, expected: {}},
      {helper: :slack, options: base, expected: {}},
      {helper: :yandex, options: camel_base.merge(accessTokenExpiresIn: 3600), expected: {access_token_expires_in: 3600}}
    ]
  end

  def with_stubbed_http_json(responses)
    requests = []
    stub = lambda do |uri, request|
      url = uri.to_s
      requests << {url: url, headers: request.to_hash}
      body = responses.fetch(url)
      StubHTTPResponse.new(JSON.generate(body))
    end

    BetterAuth::HTTPClient.stub(:request, stub) do
      yield requests
    end
  end

  StubHTTPResponse = Struct.new(:body) do
    def is_a?(klass)
      klass == Net::HTTPSuccess || super
    end
  end

  def unsigned_jwt(payload)
    JWT.encode(payload, nil, "none")
  end

  def build_auth(options = {})
    user_info = options.delete(:user_info) || {id: "oauth-sub", email: "oauth@example.com", name: "OAuth User", emailVerified: true, image: "https://example.com/avatar.png"}
    disable_implicit = options.delete(:disable_implicit_sign_up)
    provider_overrides = options.delete(:provider_overrides) || {}
    extra_options = options

    BetterAuth.auth(
      {
        base_url: "http://localhost:3000",
        secret: SECRET,
        database: :memory,
        email_and_password: {enabled: true},
        plugins: [
          BetterAuth::Plugins.generic_oauth(
            config: [
              {
                provider_id: "custom",
                authorization_url: "https://provider.example.com/authorize",
                token_url: "https://provider.example.com/token",
                issuer: "https://provider.example.com",
                client_id: "client-id",
                client_secret: "client-secret",
                scopes: ["profile", "email"],
                disable_implicit_sign_up: disable_implicit,
                get_token: ->(code:, **_data) {
                  raise "unexpected code" unless code == "oauth-code"

                  {
                    accessToken: "access-token",
                    refreshToken: "refresh-token",
                    idToken: "id-token",
                    scopes: ["openid", "email"]
                  }
                },
                get_user_info: ->(_tokens) { user_info }
              }.merge(provider_overrides)
            ]
          )
        ]
      }.merge(extra_options)
    )
  end

  def sign_up_cookie(auth, email:)
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: email, password: "password123", name: "OAuth User"},
      as_response: true
    )
    headers.fetch("set-cookie").lines.map { |line| line.split(";").first }.join("; ")
  end

  def cookie_header(set_cookie)
    set_cookie.to_s.lines.map { |line| line.split(";").first }.join("; ")
  end

  def rack_env(method, path, body: nil, cookie: nil)
    path_info, query_string = path.split("?", 2)
    payload = body ? JSON.generate(body) : ""
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path_info,
      "QUERY_STRING" => query_string || "",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "3000",
      "REMOTE_ADDR" => "127.0.0.1",
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(payload),
      "CONTENT_TYPE" => body ? "application/json" : nil,
      "CONTENT_LENGTH" => payload.bytesize.to_s,
      "HTTP_COOKIE" => cookie,
      "HTTP_ORIGIN" => "http://localhost:3000"
    }.compact
  end

  def cookie_header_without_account_data(set_cookie, auth)
    account_cookie = auth.context.auth_cookies[:account_data].name
    set_cookie.to_s.lines
      .reject { |line| line.start_with?("#{account_cookie}=") }
      .map { |line| line.split(";").first }
      .join("; ")
  end

  def decoded_account_cookie(set_cookie, auth)
    cookie_name = auth.context.auth_cookies[:account_data].name
    line = set_cookie.to_s.lines.find { |entry| entry.start_with?("#{cookie_name}=") && !entry.match?(/Max-Age=0/i) }
    value = line.to_s.split(";", 2).first.split("=", 2).last
    assert value && !value.empty?

    BetterAuth::Crypto.symmetric_decode_jwt(value, SECRET, "better-auth-account")
  end

  def with_oauth_server(requests)
    server = TCPServer.new("127.0.0.1", 0)
    @oauth_server_base_url = "http://127.0.0.1:#{server.addr[1]}"
    thread = Thread.new do
      loop do
        socket = server.accept
        request_line = socket.gets.to_s
        method, target = request_line.split
        headers = {}
        while (line = socket.gets)
          line = line.chomp
          break if line.empty?

          key, value = line.split(":", 2)
          headers[key.downcase] = value.to_s.strip
        end
        body = socket.read(headers["content-length"].to_i).to_s
        uri = URI.parse(target)
        params = (method == "POST") ? Rack::Utils.parse_nested_query(body) : Rack::Utils.parse_nested_query(uri.query.to_s)
        requests << {method: method, path: uri.path, headers: headers, params: params}
        response_body = oauth_server_response_body(uri.path, params)
        socket.write "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{response_body.bytesize}\r\nconnection: close\r\n\r\n#{response_body}"
      rescue IOError
        break
      ensure
        socket&.close
      end
    end
    yield @oauth_server_base_url
  ensure
    server&.close
    thread&.join
  end

  def oauth_server_response_body(path, params = {})
    if path == "/.well-known/openid-configuration"
      return JSON.generate(
        authorization_endpoint: "#{@oauth_server_base_url}/authorize",
        token_endpoint: "#{@oauth_server_base_url}/token",
        userinfo_endpoint: "#{@oauth_server_base_url}/userinfo",
        issuer: @oauth_server_base_url
      )
    end

    if path == "/token"
      access_token = (params["grant_type"] == "refresh_token") ? "refreshed-access-token" : "http-access-token"
      token_response = {
        access_token: access_token,
        refresh_token: "http-refresh-token",
        refresh_token_expires_in: 7200,
        scope: "openid email",
        token_type: "Bearer",
        raw_provider_field: "preserved"
      }
      token_response[:expires_in] = 3600 unless params["omit_expiry"] == "1"
      return JSON.generate(token_response)
    end

    JSON.generate(
      sub: "http-sub",
      email: "http@example.com",
      name: "HTTP User",
      email_verified: true,
      picture: "https://example.com/http.png"
    )
  end
end
