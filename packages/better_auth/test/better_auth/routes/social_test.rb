# frozen_string_literal: true

require "json"
require "uri"
require_relative "../../test_helper"

class BetterAuthRoutesSocialTest < Minitest::Test
  SECRET = "phase-five-secret-with-enough-entropy-123"

  def test_callback_oauth_endpoint_uses_upstream_id_param
    auth = build_auth

    assert_equal "/callback/:id", auth.api.endpoints.fetch(:callback_oauth).path
  end

  def test_social_provider_redirect_uri_stays_canonical_on_an_alternate_serving_origin
    redirect_uri = nil
    auth = build_auth(
      base_url: "https://auth.example.com",
      serving_origins: ["https://tenant.example.com"],
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: lambda do |data|
            redirect_uri = data.fetch(:redirect_uri)
            "https://provider.example/authorize"
          end
        }
      }
    )

    auth.api.sign_in_social(
      headers: {"host" => "tenant.example.com"},
      body: {provider: "github", callbackURL: "/", disableRedirect: true}
    )

    assert_equal "https://auth.example.com/api/auth/callback/github", redirect_uri
  end

  def test_sign_in_social_with_id_token_creates_user_account_and_session
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-1",
                email: "social@example.com",
                name: "Social User",
                image: "https://example.com/avatar.png",
                emailVerified: true
              }
            }
          }
        }
      }
    )

    status, headers, body = auth.api.sign_in_social(
      body: {provider: "github", idToken: {token: "id-token", accessToken: "access-token"}},
      as_response: true
    )
    data = JSON.parse(body.join)

    assert_equal 200, status
    assert_equal false, data.fetch("redirect")
    assert_equal "social@example.com", data.fetch("user").fetch("email")
    assert_match(/\A[0-9a-f]{32}\z/, data.fetch("token"))
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token="
    account = auth.context.internal_adapter.find_accounts(data.fetch("user").fetch("id")).find { |entry| entry["providerId"] == "github" }
    assert_equal "gh-1", account["accountId"]
    assert_equal "access-token", account["accessToken"]
  end

  def test_sign_in_social_with_id_token_rejects_blank_remote_id_without_persistence
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) { {user: {id: "  ", email: "blank-id-token@example.com", name: "Blank", emailVerified: true}} }
        }
      }
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_social(body: {provider: "github", idToken: {token: "id-token"}})
    end

    assert_equal BetterAuth::BASE_ERROR_CODES["FAILED_TO_GET_USER_INFO"], error.message
    assert_nil auth.context.internal_adapter.find_user_by_email("blank-id-token@example.com")
    assert_empty auth.context.internal_adapter.adapter.find_many(model: "account")
    assert_empty auth.context.internal_adapter.adapter.find_many(model: "session")
  end

  def test_callback_social_rejects_blank_remote_id_without_persistence
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: ->(data) { "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}" },
          validate_authorization_code: ->(_data) { {accessToken: "access"} },
          get_user_info: ->(_tokens) { {user: {id: "\t", email: "blank-callback@example.com", name: "Blank", emailVerified: true}} }
        }
      }
    )
    response = auth.api.sign_in_social(body: {provider: "github", callbackURL: "/app", errorCallbackURL: "/error", disableRedirect: true})
    state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last

    status, headers, = auth.api.callback_oauth(
      params: {providerId: "github"},
      query: {code: "code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_includes headers.fetch("location"), "error=unable_to_get_user_info"
    assert_nil auth.context.internal_adapter.find_user_by_email("blank-callback@example.com")
    assert_empty auth.context.internal_adapter.adapter.find_many(model: "account")
    assert_empty auth.context.internal_adapter.adapter.find_many(model: "session")
  end

  def test_apple_id_token_sign_in_uses_user_name_from_id_token_body
    token = fake_jwt(
      "sub" => "apple-sub",
      "email" => "apple@example.com",
      "email_verified" => true
    )
    auth = build_auth(
      social_providers: {
        apple: BetterAuth::SocialProviders.apple(
          client_id: "apple-id",
          client_secret: "apple-secret",
          verify_id_token: ->(_token, _nonce = nil) { true }
        )
      }
    )

    result = auth.api.sign_in_social(
      body: {
        provider: "apple",
        idToken: {
          token: token,
          user: {
            name: {
              firstName: "First",
              lastName: "Last"
            },
            email: "apple@example.com"
          }
        }
      }
    )

    assert_equal false, result.fetch(:redirect)
    assert_equal "First Last", result.fetch(:user).fetch("name")
  end

  def test_apple_id_token_sign_in_uses_empty_name_without_user_body
    token = fake_jwt(
      "sub" => "apple-no-name-sub",
      "email" => "apple-no-name@example.com",
      "email_verified" => true
    )
    auth = build_auth(
      social_providers: {
        apple: BetterAuth::SocialProviders.apple(
          client_id: "apple-id",
          client_secret: "apple-secret",
          verify_id_token: ->(_token, _nonce = nil) { true }
        )
      }
    )

    result = auth.api.sign_in_social(
      body: {
        provider: "apple",
        idToken: {
          token: token
        }
      }
    )

    assert_equal false, result.fetch(:redirect)
    assert_equal "apple-no-name@example.com", result.fetch(:user).fetch("email")
    assert_equal "", result.fetch(:user).fetch("name")
  end

  def test_sign_in_social_returns_authorization_url_and_callback_completes_session
    issued_code_verifier = nil
    callback_code_verifier = nil
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: lambda do |data|
            issued_code_verifier = data[:codeVerifier]
            "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}&redirect_uri=#{URI.encode_www_form_component(data[:redirectURI])}"
          end,
          validate_authorization_code: lambda do |data|
            callback_code_verifier = data[:codeVerifier]
            {accessToken: "oauth-access", refreshToken: "oauth-refresh", scopes: ["user"]}
          end,
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-2",
                email: "callback@example.com",
                name: "Callback User",
                emailVerified: true
              }
            }
          }
        }
      }
    )

    response = auth.api.sign_in_social(body: {provider: "github", callbackURL: "/app", disableRedirect: true})
    state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last

    status, headers, _body = auth.api.callback_oauth(
      params: {providerId: "github"},
      query: {code: "code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/app", headers["location"]
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token="
    user = auth.context.internal_adapter.find_user_by_email("callback@example.com")[:user]
    account = auth.context.internal_adapter.find_accounts(user["id"]).find { |entry| entry["providerId"] == "github" }
    assert_equal "oauth-refresh", account["refreshToken"]
    assert_equal "user", account["scope"]
    assert_match(/\A[0-9a-f]{32}\z/, issued_code_verifier)
    assert_equal issued_code_verifier, callback_code_verifier
  end

  def test_callback_social_redirects_to_error_when_provider_user_info_times_out
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: ->(data) { "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}" },
          validate_authorization_code: ->(_data) { {accessToken: "oauth-access"} },
          get_user_info: ->(_tokens) { raise Net::OpenTimeout }
        }
      }
    )
    response = auth.api.sign_in_social(body: {provider: "github", callbackURL: "/app", errorCallbackURL: "/auth-error", disableRedirect: true})
    state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last

    status, headers, _body = auth.api.callback_oauth(
      params: {providerId: "github"},
      query: {code: "code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/auth-error?error=unable_to_get_user_info", headers.fetch("location")
    assert_nil auth.context.internal_adapter.find_user_by_email("callback@example.com")
  end

  def test_callback_post_redirects_to_get_with_merged_body_and_query
    called = false
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: ->(data) { "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}" },
          validate_authorization_code: ->(_data) { called = true },
          get_user_info: ->(_tokens) { raise "unexpected user info call" }
        }
      }
    )
    response = auth.api.sign_in_social(body: {provider: "github", callbackURL: "/app", disableRedirect: true})
    state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last

    status, headers, _body = auth.api.callback_oauth(
      params: {providerId: "github"},
      query: {state: "query-state"},
      body: {code: "code", state: state},
      method: "POST",
      as_response: true
    )

    assert_equal 302, status
    location = headers.fetch("location")
    assert_match(%r{\Ahttp://localhost:3000/api/auth/callback/github\?}, location)
    params = Rack::Utils.parse_query(URI.parse(location).query)
    assert_equal "code", params.fetch("code")
    assert_equal state, params.fetch("state")
    refute called
  end

  def test_sign_in_social_rejects_untrusted_callback_urls
    auth = build_auth(
      trusted_origins: ["http://localhost:3000"],
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: ->(_data) { "https://github.example/oauth" }
        }
      }
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_social(
        body: {
          provider: "github",
          callbackURL: "https://evil.example/app",
          errorCallbackURL: "/error",
          newUserCallbackURL: "/welcome"
        }
      )
    end

    assert_equal BetterAuth::BASE_ERROR_CODES["INVALID_CALLBACK_URL"], error.message
  end

  def test_sign_in_social_uses_specific_callback_url_error_messages
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: ->(_data) { "https://github.example/oauth" }
        }
      }
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_social(body: {provider: "github", callbackURL: "/app", errorCallbackURL: "https://evil.example/error"})
    end
    assert_equal BetterAuth::BASE_ERROR_CODES["INVALID_ERROR_CALLBACK_URL"], error.message

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_social(body: {provider: "github", callbackURL: "/app", newUserCallbackURL: "https://evil.example/new"})
    end
    assert_equal BetterAuth::BASE_ERROR_CODES["INVALID_NEW_USER_CALLBACK_URL"], error.message
  end

  def test_sign_in_social_rejects_disabled_provider
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          enabled: false,
          create_authorization_url: ->(_data) { "https://github.example/oauth" }
        }
      }
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_social(body: {provider: "github"})
    end

    assert_equal 404, error.status_code
    assert_equal BetterAuth::BASE_ERROR_CODES["PROVIDER_NOT_FOUND"], error.message
  end

  def test_microsoft_id_token_sign_in_uses_custom_verifier
    token = fake_jwt(
      "sub" => "ms-sub",
      "aud" => "microsoft-id",
      "email" => "microsoft@example.com",
      "name" => "Microsoft User",
      "email_verified" => true
    )
    auth = build_auth(
      social_providers: {
        microsoft: BetterAuth::SocialProviders.microsoft(
          client_id: "microsoft-id",
          verify_id_token: ->(_token, _nonce = nil) { true }
        )
      }
    )

    result = auth.api.sign_in_social(
      body: {
        provider: "microsoft",
        idToken: {
          token: token,
          accessToken: "microsoft-access"
        }
      }
    )

    assert_equal false, result.fetch(:redirect)
    assert_equal "microsoft@example.com", result.fetch(:user).fetch("email")
  end

  def test_link_social_rejects_untrusted_callback_urls
    auth = build_auth(
      trusted_origins: ["http://localhost:3000"],
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: ->(_data) { "https://github.example/oauth" }
        }
      }
    )
    cookie = sign_up_cookie(auth, email: "link-url@example.com")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.link_social(
        headers: {"cookie" => cookie},
        body: {
          provider: "github",
          callbackURL: "https://evil.example/app",
          errorCallbackURL: "/error"
        }
      )
    end

    assert_equal BetterAuth::BASE_ERROR_CODES["INVALID_CALLBACK_URL"], error.message
  end

  def test_link_social_alias_matches_upstream_api_name
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: ->(_data) { "https://github.example/oauth" }
        }
      }
    )
    cookie = sign_up_cookie(auth, email: "link-upstream@example.com")

    result = auth.api.link_social(
      headers: {"cookie" => cookie},
      body: {
        provider: "github",
        callbackURL: "/dashboard",
        disableRedirect: true
      }
    )

    assert_equal "https://github.example/oauth", result[:url]
    assert_equal false, result[:redirect]
  end

  def test_sign_in_social_preserves_safe_additional_state_and_reserved_fields
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: ->(data) { "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}" }
        }
      }
    )

    response = auth.api.sign_in_social(
      body: {
        provider: "github",
        callbackURL: "/app",
        additionalData: {
          invitedBy: "user-123",
          callbackURL: "/evil",
          errorURL: "/evil-error",
          newUserURL: "/evil-new-user",
          codeVerifier: "evil-verifier",
          requestSignUp: true
        }
      }
    )
    state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last
    data = BetterAuth::Crypto.verify_jwt(state, SECRET)

    assert_equal "/app", data.fetch("callbackURL")
    assert_equal "user-123", data.fetch("invitedBy")
    refute_equal "evil-verifier", data.fetch("codeVerifier")
    refute data.key?("errorURL")
    refute data.key?("newUserURL")
    refute data["requestSignUp"]
  end

  def test_sign_in_social_rejects_implicit_signup_when_provider_disables_it
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          disableImplicitSignUp: true,
          create_authorization_url: ->(data) { "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}" },
          validate_authorization_code: ->(_data) { {accessToken: "oauth-access"} },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-disabled-signup",
                email: "disabled-signup@example.com",
                name: "Disabled Signup",
                emailVerified: true
              }
            }
          }
        }
      }
    )
    response = auth.api.sign_in_social(body: {provider: "github", callbackURL: "/app", disableRedirect: true})
    state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last

    status, headers, _body = auth.api.callback_oauth(
      params: {providerId: "github"},
      query: {code: "code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_includes headers.fetch("location"), "error=signup_disabled"
    assert_nil auth.context.internal_adapter.find_user_by_email("disabled-signup@example.com")
  end

  def test_sign_in_social_allows_requested_signup_when_implicit_signup_is_disabled
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          disableImplicitSignUp: true,
          create_authorization_url: ->(data) { "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}" },
          validate_authorization_code: ->(_data) { {accessToken: "oauth-access"} },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-requested-signup",
                email: "requested-signup@example.com",
                name: "Requested Signup",
                emailVerified: true
              }
            }
          }
        }
      }
    )
    response = auth.api.sign_in_social(body: {provider: "github", callbackURL: "/app", requestSignUp: true, disableRedirect: true})
    state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last

    status, headers, _body = auth.api.callback_oauth(
      params: {providerId: "github"},
      query: {code: "code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/app", headers.fetch("location")
    assert auth.context.internal_adapter.find_user_by_email("requested-signup@example.com")
  end

  def test_callback_rejects_invalid_signed_state
    called = false
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          validate_authorization_code: ->(_data) { called = true },
          get_user_info: ->(_tokens) { raise "unexpected user info call" }
        }
      }
    )

    status, headers, _body = auth.api.callback_oauth(
      params: {providerId: "github"},
      query: {code: "code", state: "not-a-valid-state"},
      as_response: true
    )

    assert_equal 302, status
    assert_includes headers.fetch("location"), "error=state_mismatch"
    refute called
  end

  def test_rack_callback_rejects_valid_state_without_initiating_state_cookie
    called = false
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: ->(data) { "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}" },
          validate_authorization_code: ->(_data) {
            called = true
            {accessToken: "oauth-access"}
          },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-state-cookie",
                email: "state-cookie@example.com",
                name: "State Cookie",
                emailVerified: true
              }
            }
          }
        }
      }
    )
    _status, _headers, body = auth.call(rack_env("POST", "/api/auth/sign-in/social", body: {provider: "github", callbackURL: "/app", disableRedirect: true}))
    state = URI.decode_www_form(URI.parse(JSON.parse(body.join).fetch("url")).query).assoc("state").last

    status, headers, _body = auth.call(rack_env("GET", "/api/auth/callback/github?code=code&state=#{URI.encode_www_form_component(state)}"))

    assert_equal 302, status
    assert_includes headers.fetch("location"), "error=state_mismatch"
    refute headers.fetch("set-cookie", "").include?("better-auth.session_token=")
    refute called
    assert_includes headers.fetch("set-cookie"), "better-auth.state="
  end

  def test_callback_redirects_new_social_user_to_new_user_callback_url
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: ->(data) { "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}" },
          validate_authorization_code: ->(_data) { {accessToken: "oauth-access"} },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-new-user-callback",
                email: "new-user-callback@example.com",
                name: "New User Callback",
                emailVerified: true
              }
            }
          }
        }
      }
    )

    response = auth.api.sign_in_social(
      body: {
        provider: "github",
        callbackURL: "/app",
        newUserCallbackURL: "/welcome",
        disableRedirect: true
      }
    )
    state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last

    status, headers, _body = auth.api.callback_oauth(
      params: {providerId: "github"},
      query: {code: "code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/welcome", headers.fetch("location")
  end

  def test_callback_rejects_provider_user_without_email
    auth = build_auth(
      social_providers: {
        discord: {
          id: "discord",
          create_authorization_url: ->(data) { "https://discord.example/oauth?state=#{URI.encode_www_form_component(data[:state])}" },
          validate_authorization_code: ->(_data) { {accessToken: "discord-access"} },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "discord-no-email",
                email: nil,
                name: "Phone Only",
                emailVerified: false
              }
            }
          }
        }
      }
    )
    response = auth.api.sign_in_social(body: {provider: "discord", callbackURL: "/app", disableRedirect: true})
    state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last

    status, headers, _body = auth.api.callback_oauth(
      params: {providerId: "discord"},
      query: {code: "code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_includes headers.fetch("location"), "error=email_not_found"
    assert_nil auth.context.internal_adapter.find_user_by_email("discord-no-email@example.com")
  end

  def test_callback_rejects_signup_when_provider_disables_signup
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          disableSignUp: true,
          create_authorization_url: ->(data) { "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}" },
          validate_authorization_code: ->(_data) { {accessToken: "oauth-access"} },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-signup-disabled",
                email: "signup-disabled@example.com",
                name: "Signup Disabled",
                emailVerified: true
              }
            }
          }
        }
      }
    )

    response = auth.api.sign_in_social(body: {provider: "github", callbackURL: "/app", requestSignUp: true, disableRedirect: true})
    state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last

    status, headers, _body = auth.api.callback_oauth(
      params: {providerId: "github"},
      query: {code: "code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_includes headers.fetch("location"), "error=signup_disabled"
    assert_nil auth.context.internal_adapter.find_user_by_email("signup-disabled@example.com")
  end

  def test_vercel_callback_creates_user_and_existing_user_uses_callback_url
    token_exchange = ->(_url, _form, _headers = {}) { {"access_token" => "vercel-access"} }
    provider = BetterAuth::SocialProviders.vercel(
      client_id: "vercel-id",
      client_secret: "vercel-secret",
      get_user_info: ->(_tokens) {
        {
          "sub" => "vercel-sub",
          "preferred_username" => "vercel-user",
          "email" => "vercel-callback@example.com",
          "email_verified" => true
        }
      }
    )
    auth = build_auth(social_providers: {vercel: provider})

    BetterAuth::SocialProviders::Base.stub(:post_form_json, token_exchange) do
      response = auth.api.sign_in_social(body: {provider: "vercel", callbackURL: "/app", newUserCallbackURL: "/welcome", disableRedirect: true})
      state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last
      status, headers, _body = auth.api.callback_oauth(
        params: {providerId: "vercel"},
        query: {code: "code", state: state},
        as_response: true
      )

      assert_equal 302, status
      assert_equal "/welcome", headers.fetch("location")
      assert_equal "vercel-user", auth.context.internal_adapter.find_user_by_email("vercel-callback@example.com")[:user]["name"]

      second_response = auth.api.sign_in_social(body: {provider: "vercel", callbackURL: "/app", newUserCallbackURL: "/welcome", disableRedirect: true})
      second_state = URI.decode_www_form(URI.parse(second_response[:url]).query).assoc("state").last
      status, headers, _body = auth.api.callback_oauth(
        params: {providerId: "vercel"},
        query: {code: "code", state: second_state},
        as_response: true
      )

      assert_equal 302, status
      assert_equal "/app", headers.fetch("location")
    end
  end

  def test_railway_callback_creates_user_with_unverified_email
    token_exchange = ->(_url, _form, _headers = {}) { {"access_token" => "railway-access"} }
    provider = BetterAuth::SocialProviders.railway(
      client_id: "railway-id",
      client_secret: "railway-secret",
      get_user_info: ->(_tokens) {
        {
          "sub" => "railway-sub",
          "name" => "Railway User",
          "email" => "railway-callback@example.com"
        }
      }
    )
    auth = build_auth(social_providers: {railway: provider})

    BetterAuth::SocialProviders::Base.stub(:post_form_json, token_exchange) do
      response = auth.api.sign_in_social(body: {provider: "railway", callbackURL: "/app", disableRedirect: true})
      state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last
      status, headers, _body = auth.api.callback_oauth(
        params: {providerId: "railway"},
        query: {code: "code", state: state},
        as_response: true
      )

      assert_equal 302, status
      assert_equal "/app", headers.fetch("location")
      user = auth.context.internal_adapter.find_user_by_email("railway-callback@example.com")[:user]
      assert_equal "Railway User", user["name"]
      assert_equal false, user["emailVerified"]
    end
  end

  def test_sign_in_social_rejects_unverified_implicit_linking_from_untrusted_provider
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-unverified-link",
                email: "unverified-link@example.com",
                name: "Unverified Link",
                emailVerified: false
              }
            }
          }
        }
      }
    )
    sign_up_cookie(auth, email: "unverified-link@example.com")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_social(body: {provider: "github", idToken: {token: "id-token"}})
    end

    assert_equal "account not linked", error.message
    user = auth.context.internal_adapter.find_user_by_email("unverified-link@example.com")[:user]
    assert_empty auth.context.internal_adapter.find_accounts(user["id"]).reject { |account| account["providerId"] == "credential" }
  end

  def test_link_social_with_id_token_links_account_to_current_user
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-linked",
                email: "link@example.com",
                name: "Linked",
                emailVerified: true
              }
            }
          }
        }
      },
      account: {account_linking: {trusted_providers: ["github"]}}
    )
    cookie = sign_up_cookie(auth, email: "link@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]

    result = auth.api.link_social(
      headers: {"cookie" => cookie},
      body: {provider: "github", idToken: {token: "id-token", accessToken: "access-token"}}
    )

    assert_equal({url: "", status: true, redirect: false}, result)
    account = auth.context.internal_adapter.find_accounts(user_id).find { |entry| entry["providerId"] == "github" }
    assert_equal "gh-linked", account["accountId"]
  end

  def test_link_social_with_verified_matching_email_marks_user_email_verified
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-verified-link",
                email: "verified-link@example.com",
                name: "Verified Link",
                emailVerified: true
              }
            }
          }
        }
      },
      account: {account_linking: {trusted_providers: ["github"]}}
    )
    cookie = sign_up_cookie(auth, email: "verified-link@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]

    auth.api.link_social(
      headers: {"cookie" => cookie},
      body: {provider: "github", idToken: {token: "id-token"}}
    )

    user = auth.context.internal_adapter.find_user_by_id(user_id)
    assert_equal true, user["emailVerified"]
  end

  def test_link_social_with_unverified_matching_email_leaves_user_unverified
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-unverified-link",
                email: "unverified-link@example.com",
                name: "Unverified Link",
                emailVerified: false
              }
            }
          }
        }
      },
      account: {account_linking: {trusted_providers: ["github"]}}
    )
    cookie = sign_up_cookie(auth, email: "unverified-link@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]

    auth.api.link_social(
      headers: {"cookie" => cookie},
      body: {provider: "github", idToken: {token: "id-token"}}
    )

    user = auth.context.internal_adapter.find_user_by_id(user_id)
    assert_equal false, user["emailVerified"]
  end

  def test_link_social_with_verified_different_email_does_not_mark_user_verified
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-different-email",
                email: "provider-different@example.com",
                name: "Different Email",
                emailVerified: true
              }
            }
          }
        }
      },
      account: {account_linking: {trusted_providers: ["github"], allow_different_emails: true}}
    )
    cookie = sign_up_cookie(auth, email: "different-email@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]

    auth.api.link_social(
      headers: {"cookie" => cookie},
      body: {provider: "github", idToken: {token: "id-token"}}
    )

    user = auth.context.internal_adapter.find_user_by_id(user_id)
    assert_equal false, user["emailVerified"]
  end

  def test_link_social_with_already_verified_user_remains_verified
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-already-verified",
                email: "already-verified@example.com",
                name: "Already Verified",
                emailVerified: true
              }
            }
          }
        }
      },
      account: {account_linking: {trusted_providers: ["github"]}}
    )
    cookie = sign_up_cookie(auth, email: "already-verified@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    auth.context.internal_adapter.update_user(user_id, "emailVerified" => true)

    auth.api.link_social(
      headers: {"cookie" => cookie},
      body: {provider: "github", idToken: {token: "id-token"}}
    )

    user = auth.context.internal_adapter.find_user_by_id(user_id)
    assert_equal true, user["emailVerified"]
  end

  def test_link_social_redirect_flow_links_account_on_callback
    issued_code_verifier = nil
    callback_code_verifier = nil
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: lambda do |data|
            issued_code_verifier = data[:codeVerifier]
            "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}"
          end,
          validate_authorization_code: lambda do |data|
            callback_code_verifier = data[:codeVerifier]
            {accessToken: "linked-access", refreshToken: "linked-refresh"}
          end,
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-redirect-linked",
                email: "redirect-link@example.com",
                name: "Redirect Link",
                emailVerified: true
              }
            }
          }
        }
      },
      account: {account_linking: {trusted_providers: ["github"]}}
    )
    cookie = sign_up_cookie(auth, email: "redirect-link@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]

    response = auth.api.link_social(
      headers: {"cookie" => cookie},
      body: {provider: "github", callbackURL: "/linked", disableRedirect: true}
    )
    state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last

    status, headers, _body = auth.api.callback_oauth(
      params: {providerId: "github"},
      query: {code: "code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/linked", headers.fetch("location")
    refute_includes headers.fetch("set-cookie", ""), "better-auth.session_token="
    account = auth.context.internal_adapter.find_accounts(user_id).find { |entry| entry["providerId"] == "github" }
    assert_equal "gh-redirect-linked", account["accountId"]
    assert_equal "linked-refresh", account["refreshToken"]
    assert_match(/\A[0-9a-f]{32}\z/, issued_code_verifier)
    assert_equal issued_code_verifier, callback_code_verifier
  end

  def test_link_social_redirect_flow_passes_custom_scopes_to_provider
    captured_scopes = nil
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: lambda do |data|
            captured_scopes = data[:scopes]
            "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}"
          end,
          validate_authorization_code: ->(_data) { raise "unexpected callback" },
          get_user_info: ->(_tokens) { raise "unexpected user info" }
        }
      }
    )
    cookie = sign_up_cookie(auth, email: "link-scopes@example.com")

    result = auth.api.link_social(
      headers: {"cookie" => cookie},
      body: {
        provider: "github",
        callbackURL: "/linked",
        disableRedirect: true,
        scopes: ["repo", "user:email"]
      }
    )

    assert_equal ["repo", "user:email"], captured_scopes
    assert_equal false, result[:redirect]
    assert_includes result[:url], "github.example/oauth"
  end

  def test_link_social_redirect_flow_links_account_when_email_casing_differs
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: ->(data) { "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}" },
          validate_authorization_code: ->(_data) { {accessToken: "linked-access"} },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-casing",
                email: "Casing-Link@Example.com",
                name: "Casing Link",
                emailVerified: true
              }
            }
          }
        }
      },
      account: {account_linking: {trusted_providers: ["github"]}}
    )
    cookie = sign_up_cookie(auth, email: "casing-link@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]

    response = auth.api.link_social(
      headers: {"cookie" => cookie},
      body: {provider: "github", callbackURL: "/linked", disableRedirect: true}
    )
    state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last

    status, headers, _body = auth.api.callback_oauth(
      params: {providerId: "github"},
      query: {code: "code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/linked", headers.fetch("location")
    account = auth.context.internal_adapter.find_accounts(user_id).find { |entry| entry["providerId"] == "github" }
    assert_equal "gh-casing", account["accountId"]
    assert_equal true, auth.context.internal_adapter.find_user_by_id(user_id)["emailVerified"]
  end

  def test_sign_in_social_rejects_verified_provider_for_unverified_local_user_by_default
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-verified-implicit",
                email: "verified-implicit@example.com",
                name: "Verified Implicit",
                emailVerified: true
              }
            }
          }
        }
      },
      account: {account_linking: {trusted_providers: []}}
    )
    cookie = sign_up_cookie(auth, email: "verified-implicit@example.com")
    user = auth.context.internal_adapter.find_user_by_email("verified-implicit@example.com")[:user]
    old_session_tokens = auth.context.internal_adapter.list_sessions(user["id"]).map { |session| session["token"] }

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_social(body: {provider: "github", idToken: {token: "id-token"}}, headers: {"cookie" => cookie})
    end

    assert_equal "account not linked", error.message
    refute auth.context.internal_adapter.find_accounts(user["id"]).any? { |entry| entry["providerId"] == "github" }
    assert_equal old_session_tokens, auth.context.internal_adapter.list_sessions(user["id"]).map { |session| session["token"] }
    refute auth.context.internal_adapter.find_user_by_id(user["id"])["emailVerified"]
  end

  def test_rejected_implicit_link_does_not_create_session_for_banned_user_when_delete_is_vetoed
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) {
            {user: {id: "gh-banned-veto", email: "banned-veto@example.com", name: "Banned", emailVerified: true}}
          }
        }
      },
      user: {
        additional_fields: {
          banned: {type: "boolean", default_value: false, input: false}
        }
      },
      database_hooks: {
        session: {delete: {before: ->(_session, _context) { false }}}
      }
    )
    sign_up_cookie(auth, email: "banned-veto@example.com")
    user = auth.context.internal_adapter.find_user_by_email("banned-veto@example.com").fetch(:user)
    auth.context.internal_adapter.update_user(user.fetch("id"), banned: true)
    session_count = auth.context.internal_adapter.list_sessions(user.fetch("id")).length

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_social(body: {provider: "github", idToken: {token: "id-token"}})
    end

    assert_equal "banned", error.message
    assert_equal session_count, auth.context.internal_adapter.list_sessions(user.fetch("id")).length
    assert_nil auth.context.internal_adapter.find_account_by_provider_id("gh-banned-veto", "github")
  end

  def test_expired_ban_runs_the_final_social_session_hook_once_without_delete_preflight
    session_create_hooks = 0
    session_delete_hooks = 0
    auth = build_auth(
      plugins: [BetterAuth::Plugins.admin],
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) {
            {user: {id: "gh-expired-ban", email: "expired-ban@example.com", name: "Expired Ban", emailVerified: true}}
          }
        }
      },
      database_hooks: {
        session: {
          create: {before: ->(_session, _context) { session_create_hooks += 1 }},
          delete: {before: ->(_session, _context) { session_delete_hooks += 1 }}
        }
      }
    )
    sign_up_cookie(auth, email: "expired-ban@example.com")
    user = auth.context.internal_adapter.find_user_by_email("expired-ban@example.com").fetch(:user)
    auth.context.internal_adapter.update_user(
      user.fetch("id"),
      emailVerified: true,
      banned: true,
      banReason: "Expired",
      banExpires: Time.now - 60
    )
    session_count = auth.context.internal_adapter.list_sessions(user.fetch("id")).length
    session_create_hooks = 0
    session_delete_hooks = 0

    result = auth.api.sign_in_social(body: {provider: "github", idToken: {token: "id-token"}})

    assert_equal user.fetch("id"), result.fetch(:user).fetch("id")
    assert_equal false, auth.context.internal_adapter.find_user_by_id(user.fetch("id")).fetch("banned")
    assert_equal session_count + 1, auth.context.internal_adapter.list_sessions(user.fetch("id")).length
    assert_equal 1, session_create_hooks
    assert_equal 0, session_delete_hooks
  end

  def test_sign_in_social_implicitly_links_verified_local_user
    provider_user = {
      id: "gh-verified-local",
      email: "verified-local@example.com",
      name: "Verified Local",
      emailVerified: true
    }
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) { {user: provider_user} }
        }
      }
    )
    sign_up_cookie(auth, email: provider_user[:email])
    user = auth.context.internal_adapter.find_user_by_email(provider_user[:email])[:user]
    auth.context.internal_adapter.update_user(user["id"], emailVerified: true)

    result = auth.api.sign_in_social(body: {provider: "github", idToken: {token: "id-token"}})

    assert_equal user["id"], result[:user]["id"]
    assert auth.context.internal_adapter.find_account_by_provider_id(provider_user[:id], "github")
  end

  def test_sign_in_social_require_local_email_verified_opt_out_supports_snake_and_camel_case
    [
      {account: {account_linking: {require_local_email_verified: false}}},
      {account: {accountLinking: {requireLocalEmailVerified: false}}}
    ].each_with_index do |linking_options, index|
      email = "social-opt-out-#{index}@example.com"
      remote_id = "social-opt-out-#{index}"
      auth = build_auth(
        linking_options.merge(
          social_providers: {
            github: {
              id: "github",
              verify_id_token: ->(_token, _nonce = nil) { true },
              get_user_info: ->(_tokens) { {user: {id: remote_id, email: email, name: "Opt Out", emailVerified: true}} }
            }
          }
        )
      )
      sign_up_cookie(auth, email: email)

      result = auth.api.sign_in_social(body: {provider: "github", idToken: {token: "id-token"}})

      assert_equal true, result[:user]["emailVerified"]
      assert auth.context.internal_adapter.find_account_by_provider_id(remote_id, "github")
    end
  end

  def test_implicit_link_rolls_back_account_and_session_when_verified_email_promotion_is_vetoed
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) {
            {user: {id: "gh-promotion-veto", email: "promotion-veto@example.com", name: "Veto", emailVerified: true}}
          }
        }
      },
      account: {account_linking: {require_local_email_verified: false}},
      database_hooks: {
        user: {
          update: {
            before: ->(data, _context) { false if data["emailVerified"] == true }
          }
        }
      }
    )
    sign_up_cookie(auth, email: "promotion-veto@example.com")
    user = auth.context.internal_adapter.find_user_by_email("promotion-veto@example.com").fetch(:user)
    session_count = auth.context.internal_adapter.list_sessions(user.fetch("id")).length

    assert_raises(BetterAuth::Error) do
      auth.api.sign_in_social(body: {provider: "github", idToken: {token: "id-token"}})
    end

    assert_nil auth.context.internal_adapter.find_account_by_provider_id("gh-promotion-veto", "github")
    refute auth.context.internal_adapter.find_user_by_id(user.fetch("id")).fetch("emailVerified")
    assert_equal session_count, auth.context.internal_adapter.list_sessions(user.fetch("id")).length
  end

  def test_sign_in_social_disable_implicit_linking_blocks_existing_user_but_allows_new_user
    provider_user = {
      id: "gh-existing-implicit",
      email: "implicit-block-account@example.com",
      name: "Implicit Block",
      emailVerified: true
    }
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) { {user: provider_user} }
        }
      },
      account: {account_linking: {disable_implicit_linking: true, trusted_providers: ["github"]}}
    )
    sign_up_cookie(auth, email: "implicit-block-account@example.com")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_social(body: {provider: "github", idToken: {token: "id-token"}})
    end
    assert_equal "account not linked", error.message

    provider_user = {
      id: "gh-new-implicit",
      email: "new-implicit-user@example.com",
      name: "New Implicit",
      emailVerified: true
    }
    result = auth.api.sign_in_social(body: {provider: "github", idToken: {token: "id-token"}})
    assert_equal "new-implicit-user@example.com", result.fetch(:user).fetch("email")
  end

  def test_sign_in_social_override_user_info_cannot_bypass_local_verification_gate
    provider_user = {
      id: "gh-override",
      email: "override-social@example.com",
      name: "Updated Social Name",
      image: "https://example.com/updated.png",
      emailVerified: true
    }
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          overrideUserInfoOnSignIn: true,
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) { {user: provider_user} }
        }
      },
      account: {account_linking: {trusted_providers: ["github"]}}
    )
    cookie = sign_up_cookie(auth, email: "override-social@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    auth.context.internal_adapter.update_user(user_id, "name" => "Initial Name", "emailVerified" => false)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_social(body: {provider: "github", idToken: {token: "id-token", accessToken: "access-token"}})
    end

    user = auth.context.internal_adapter.find_user_by_id(user_id)
    assert_equal "account not linked", error.message
    assert_equal "Initial Name", user["name"]
    assert_nil user["image"]
    assert_equal false, user["emailVerified"]
    refute auth.context.internal_adapter.find_account_by_provider_id("gh-override", "github")
  end

  def test_sign_in_social_does_not_update_linked_account_tokens_when_disabled
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-no-update",
                email: "no-update-account@example.com",
                name: "No Update",
                emailVerified: true
              }
            }
          }
        }
      },
      account: {update_account_on_sign_in: false, account_linking: {trusted_providers: ["github"]}}
    )
    cookie = sign_up_cookie(auth, email: "no-update-account@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    account = auth.context.internal_adapter.create_account(
      "providerId" => "github",
      "accountId" => "gh-no-update",
      "userId" => user_id,
      "accessToken" => "preserved-access"
    )

    auth.api.sign_in_social(body: {provider: "github", idToken: {token: "new-id-token", accessToken: "new-access"}})

    stored = auth.context.internal_adapter.find_accounts(user_id).find { |entry| entry["id"] == account["id"] }
    assert_equal "preserved-access", stored["accessToken"]
    assert_nil stored["idToken"]
  end

  def test_sign_in_social_updates_linked_account_tokens_by_default
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-update",
                email: "update-account@example.com",
                name: "Update Account",
                emailVerified: true
              }
            }
          }
        }
      }
    )
    cookie = sign_up_cookie(auth, email: "update-account@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    account = auth.context.internal_adapter.create_account(
      "providerId" => "github",
      "accountId" => "gh-update",
      "userId" => user_id,
      "accessToken" => "old-access"
    )

    auth.api.sign_in_social(body: {provider: "github", idToken: {token: "new-id-token", accessToken: "new-access"}})

    stored = auth.context.internal_adapter.find_accounts(user_id).find { |entry| entry["id"] == account["id"] }
    assert_equal "new-access", stored["accessToken"]
    assert_equal "new-id-token", stored["idToken"]
  end

  def test_link_social_redirect_flow_rejects_account_owned_by_another_user
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: ->(data) { "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}" },
          validate_authorization_code: ->(_data) { {accessToken: "linked-access"} },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-owned",
                email: "owner-one@example.com",
                name: "Owned",
                emailVerified: true
              }
            }
          }
        }
      },
      account: {account_linking: {trusted_providers: ["github"], allow_different_emails: true}}
    )
    first_cookie = sign_up_cookie(auth, email: "owner-one@example.com")
    first_user_id = auth.api.get_session(headers: {"cookie" => first_cookie})[:user]["id"]
    auth.context.internal_adapter.create_account({
      "providerId" => "github",
      "accountId" => "gh-owned",
      "userId" => first_user_id
    })
    second_cookie = sign_up_cookie(auth, email: "owner-two@example.com")

    response = auth.api.link_social(
      headers: {"cookie" => second_cookie},
      body: {provider: "github", callbackURL: "/linked", disableRedirect: true}
    )
    state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last

    status, headers, _body = auth.api.callback_oauth(
      params: {providerId: "github"},
      query: {code: "code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_includes headers.fetch("location"), "error=account_already_linked_to_different_user"
  end

  def test_link_social_rejects_when_account_linking_is_disabled
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-disabled-link",
                email: "disabled-link@example.com",
                name: "Disabled Link",
                emailVerified: true
              }
            }
          }
        }
      },
      account: {account_linking: {enabled: false, trusted_providers: ["github"]}}
    )
    cookie = sign_up_cookie(auth, email: "disabled-link@example.com")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.link_social(
        headers: {"cookie" => cookie},
        body: {provider: "github", idToken: {token: "id-token"}}
      )
    end

    assert_equal "Account not linked - untrusted provider", error.message
  end

  def test_generic_provider_without_id_token_verifier_rejects_id_token_sign_in
    provider = BetterAuth::SocialProviders::Base.oauth_provider(
      id: "example",
      name: "Example",
      client_id: "id",
      client_secret: "secret",
      authorization_endpoint: "https://provider.example/authorize",
      token_endpoint: "https://provider.example/token",
      profile_map: ->(profile) {
        {
          id: profile.fetch("sub"),
          email: profile.fetch("email"),
          name: profile.fetch("name"),
          emailVerified: true
        }
      }
    )
    auth = build_auth(social_providers: {example: provider})

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_social(
        body: {
          provider: "example",
          idToken: {
            token: fake_jwt("sub" => "example-sub", "email" => "example@example.com", "name" => "Example")
          }
        }
      )
    end

    assert_equal 404, error.status_code
    assert_equal BetterAuth::BASE_ERROR_CODES["ID_TOKEN_NOT_SUPPORTED"], error.message
  end

  def test_provider_mapped_fields_are_filtered_and_coerced_on_create_and_override
    profile = {
      id: "mapped-profile-account",
      email: "mapped-profile@example.com",
      name: "Created Name",
      image: "https://example.com/created.png",
      emailVerified: true,
      mappedCode: "created-code",
      mappedAt: "2026-07-13T10:20:30Z",
      serverRole: "admin",
      unknownField: "discard me"
    }
    auth = build_auth(
      user: {additional_fields: mapped_profile_fields},
      social_providers: {
        github: {
          id: "github",
          overrideUserInfoOnSignIn: true,
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) { {user: profile.dup} }
        }
      }
    )

    auth.api.sign_in_social(body: {provider: "github", idToken: {token: "create-token"}})
    created = auth.context.internal_adapter.find_user_by_email("mapped-profile@example.com").fetch(:user)

    assert_equal "created-code", created.fetch("mappedCode")
    assert_equal Time.utc(2026, 7, 13, 10, 20, 30), created.fetch("mappedAt")
    assert_equal "member", created.fetch("serverRole")
    refute created.key?("unknownField")

    profile = profile.merge(
      name: "Updated Name",
      mappedCode: "updated-code",
      mappedAt: "2026-07-14T11:22:33Z",
      serverRole: "owner"
    )
    auth.api.sign_in_social(body: {provider: "github", idToken: {token: "update-token"}})
    updated = auth.context.internal_adapter.find_user_by_id(created.fetch("id"))

    assert_equal "Updated Name", updated.fetch("name")
    assert_equal "updated-code", updated.fetch("mappedCode")
    assert_equal Time.utc(2026, 7, 14, 11, 22, 33), updated.fetch("mappedAt")
    assert_equal "member", updated.fetch("serverRole")
  end

  def test_update_user_info_on_link_persists_filtered_mapped_fields_without_rebinding_identity
    auth = build_auth(
      user: {additional_fields: mapped_profile_fields},
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: ->(data) { "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}" },
          validate_authorization_code: ->(_data) { {accessToken: "link-access-token"} },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "remote-link-account",
                email: "different-provider@example.com",
                name: "Linked Name",
                image: "https://example.com/linked.png",
                emailVerified: true,
                mappedCode: "linked-code",
                mappedAt: "2026-07-15T12:00:00Z",
                serverRole: "admin",
                unknownField: "discard me"
              }
            }
          }
        }
      },
      account: {
        account_linking: {
          trusted_providers: ["github"],
          allow_different_emails: true,
          update_user_info_on_link: true
        }
      }
    )
    cookie = sign_up_cookie(auth, email: "local-link@example.com")
    original = auth.context.internal_adapter.find_user_by_email("local-link@example.com").fetch(:user)
    response = auth.api.link_social(
      headers: {"cookie" => cookie},
      body: {provider: "github", callbackURL: "/linked", disableRedirect: true}
    )
    state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last

    status, headers, = auth.api.callback_oauth(
      params: {providerId: "github"},
      query: {code: "code", state: state},
      as_response: true
    )
    updated = auth.context.internal_adapter.find_user_by_id(original.fetch("id"))

    assert_equal 302, status
    assert_equal "/linked", headers.fetch("location")
    assert_equal original.fetch("id"), updated.fetch("id")
    assert_equal "local-link@example.com", updated.fetch("email")
    assert_equal false, updated.fetch("emailVerified")
    assert_equal "Linked Name", updated.fetch("name")
    assert_equal "https://example.com/linked.png", updated.fetch("image")
    assert_equal "linked-code", updated.fetch("mappedCode")
    assert_equal Time.utc(2026, 7, 15, 12), updated.fetch("mappedAt")
    assert_equal "member", updated.fetch("serverRole")
    refute updated.key?("unknownField")
  end

  def test_social_query_failure_uses_a_safe_fixed_message_with_a_callable_logger
    entries = []
    logger = ->(*arguments) { entries << arguments }
    auth = build_auth(
      logger: logger,
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) {
            {user: {id: "query-account", email: "email-sentinel@example.com", name: "Profile Sentinel", emailVerified: true}}
          }
        }
      }
    )
    entries.clear
    failure = ->(*) { raise "EXCEPTION_SENTINEL TOKEN_SENTINEL PROFILE_SENTINEL EMAIL_SENTINEL" }

    error = assert_raises(BetterAuth::APIError) do
      auth.context.internal_adapter.stub(:find_oauth_user, failure) do
        auth.api.sign_in_social(body: {provider: "github", idToken: {token: "TOKEN_SENTINEL"}})
      end
    end

    assert_equal "internal server error", error.message
    assert_safe_social_log(entries, [:error, "Unable to query social user"])
  end

  def test_social_create_failure_uses_a_safe_fixed_message_with_a_callable_logger
    entries = []
    logger = ->(*arguments) { entries << arguments }
    auth = build_auth(
      logger: logger,
      user: {
        additional_fields: {
          serverValue: {
            type: "string",
            input: false,
            default_value: -> { raise "EXCEPTION_SENTINEL TOKEN_SENTINEL PROFILE_SENTINEL EMAIL_SENTINEL" }
          }
        }
      },
      social_providers: {
        github: {
          id: "github",
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "create-account",
                email: "email-sentinel@example.com",
                name: "Profile Sentinel",
                emailVerified: true,
                profileSentinel: "PROFILE_SENTINEL"
              }
            }
          }
        }
      }
    )
    entries.clear

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_social(body: {provider: "github", idToken: {token: "TOKEN_SENTINEL"}})
    end

    assert_equal "unable to create user", error.message
    assert_safe_social_log(entries, [:error, "Unable to create social user"])
  end

  def test_social_link_failure_uses_a_safe_fixed_message_with_an_object_logger
    entries = []
    logger = recording_logger(entries)
    auth = build_auth(
      logger: logger,
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: ->(data) { "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}" },
          validate_authorization_code: ->(_data) { {accessToken: "TOKEN_SENTINEL"} },
          get_user_info: ->(_tokens) {
            {user: {id: "link-account", email: "email-sentinel@example.com", name: "Profile Sentinel", emailVerified: true}}
          }
        }
      },
      account: {account_linking: {trusted_providers: ["github"], allow_different_emails: true}}
    )
    cookie = sign_up_cookie(auth, email: "local-safe-link@example.com")
    response = auth.api.link_social(
      headers: {"cookie" => cookie},
      body: {provider: "github", callbackURL: "/linked", errorCallbackURL: "/error", disableRedirect: true}
    )
    state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last
    entries.clear
    failure = ->(*) { raise "EXCEPTION_SENTINEL TOKEN_SENTINEL PROFILE_SENTINEL EMAIL_SENTINEL" }

    status, headers, = auth.context.internal_adapter.stub(:create_account, failure) do
      auth.api.callback_oauth(
        params: {providerId: "github"},
        query: {code: "code", state: state},
        as_response: true
      )
    end

    assert_equal 302, status
    assert_includes headers.fetch("location"), "error=unable_to_link_account"
    assert_safe_social_log(entries, [:error, "Unable to link social account"])
  end

  def test_override_mapped_profile_failure_is_fatal_and_logs_safely_with_an_object_logger
    entries = []
    logger = recording_logger(entries)
    profile = {
      id: "override-safe-account",
      email: "email-sentinel@example.com",
      name: "Original Name",
      emailVerified: true,
      mappedAt: "2026-07-13T00:00:00Z"
    }
    auth = build_auth(
      logger: logger,
      user: {additional_fields: {mappedAt: {type: "date", required: false}}},
      social_providers: {
        github: {
          id: "github",
          overrideUserInfoOnSignIn: true,
          verify_id_token: ->(_token, _nonce = nil) { true },
          get_user_info: ->(_tokens) { {user: profile.dup} }
        }
      }
    )
    created = auth.api.sign_in_social(body: {provider: "github", idToken: {token: "first-token"}})
    entries.clear
    profile = profile.merge(name: "Profile Sentinel", mappedAt: "PROFILE_SENTINEL")

    error = assert_raises(ArgumentError) do
      auth.api.sign_in_social(body: {provider: "github", idToken: {token: "TOKEN_SENTINEL"}})
    end

    assert_includes error.message, "no time information"
    assert_equal "Original Name", auth.context.internal_adapter.find_user_by_id(created.fetch(:user).fetch("id")).fetch("name")
    assert_safe_social_log(entries, [:warn, "Could not override social user info"])
  end

  def test_update_user_info_on_link_failure_is_nonfatal_and_logs_safely_with_a_callable_logger
    entries = []
    logger = ->(*arguments) { entries << arguments }
    auth = build_auth(
      logger: logger,
      user: {additional_fields: {mappedAt: {type: "date", required: false}}},
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: ->(data) { "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}" },
          validate_authorization_code: ->(_data) { {accessToken: "TOKEN_SENTINEL"} },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "update-link-safe-account",
                email: "email-sentinel@example.com",
                name: "Profile Sentinel",
                emailVerified: true,
                mappedAt: "PROFILE_SENTINEL"
              }
            }
          }
        }
      },
      account: {
        account_linking: {
          trusted_providers: ["github"],
          allow_different_emails: true,
          update_user_info_on_link: true
        }
      }
    )
    cookie = sign_up_cookie(auth, email: "local-safe-update-link@example.com")
    response = auth.api.link_social(
      headers: {"cookie" => cookie},
      body: {provider: "github", callbackURL: "/linked", disableRedirect: true}
    )
    state = URI.decode_www_form(URI.parse(response[:url]).query).assoc("state").last
    entries.clear

    status, headers, = auth.api.callback_oauth(
      params: {providerId: "github"},
      query: {code: "code", state: state},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/linked", headers.fetch("location")
    assert_safe_social_log(entries, [:warn, "Could not update user info on account link"])
  end

  private

  def build_auth(options = {})
    email_and_password = {enabled: true}.merge(options.fetch(:email_and_password, {}))
    BetterAuth.auth({base_url: "http://localhost:3000", secret: SECRET, database: :memory}.merge(options).merge(email_and_password: email_and_password))
  end

  def mapped_profile_fields
    {
      mappedCode: {type: "string", required: false},
      mappedAt: {type: "date", required: false},
      serverRole: {type: "string", required: false, input: false, default_value: "member"}
    }
  end

  def recording_logger(entries)
    Object.new.tap do |logger|
      [:error, :warn, :info, :debug].each do |level|
        logger.define_singleton_method(level) { |*arguments| entries << [level, *arguments] }
      end
    end
  end

  def assert_safe_social_log(entries, expected)
    assert_equal [expected], entries
    rendered = entries.flatten.join(" ")
    %w[TOKEN_SENTINEL PROFILE_SENTINEL EMAIL_SENTINEL EXCEPTION_SENTINEL email-sentinel@example.com].each do |sentinel|
      refute_includes rendered, sentinel
    end
  end

  def sign_up_cookie(auth, email:)
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: email, password: "password123", name: "Social User"},
      as_response: true
    )
    headers.fetch("set-cookie").lines.map { |line| line.split(";").first }.join("; ")
  end

  def fake_jwt(payload)
    encoded_header = Base64.urlsafe_encode64(JSON.generate({"alg" => "none"}), padding: false)
    encoded_payload = Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
    "#{encoded_header}.#{encoded_payload}."
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
end
