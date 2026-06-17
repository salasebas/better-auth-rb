# frozen_string_literal: true

require_relative "../../test_helper"

class OAuthProviderUserinfoTest < Minitest::Test
  include OAuthProviderFlowHelpers

  def test_userinfo_rejects_missing_authorization_header_as_invalid_request
    auth = build_auth(scopes: ["openid"])

    error = assert_raises(BetterAuth::APIError) do
      auth.api.oauth2_user_info(headers: {})
    end

    assert_equal 401, error.status_code
    assert_equal "invalid_request", error.body[:error]
    assert_match(/authorization header not found/, error.body[:error_description])
  end

  def test_userinfo_without_openid_scope_is_bad_request
    auth = build_auth(scopes: ["openid", "profile"])
    cookie = sign_up_cookie(auth)
    client = create_client(
      auth,
      cookie,
      grant_types: ["authorization_code"],
      response_types: ["code"],
      scope: "profile"
    )
    tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "profile")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.oauth2_user_info(headers: {"authorization" => "Bearer #{tokens[:access_token]}"})
    end

    assert_equal 400, error.status_code
    assert_equal "invalid_request", error.body[:error]
  end

  def test_userinfo_returns_sub_only_for_openid_scope
    auth = build_auth(scopes: ["openid", "profile", "email"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, grant_types: ["authorization_code"], response_types: ["code"], scope: "openid profile email")
    tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid")

    userinfo = auth.api.oauth2_user_info(headers: {"authorization" => "Bearer #{tokens[:access_token]}"})

    assert userinfo[:sub]
    refute userinfo.key?(:name)
    refute userinfo.key?(:given_name)
    refute userinfo.key?(:family_name)
    refute userinfo.key?(:email)
    refute userinfo.key?(:email_verified)
  end

  def test_userinfo_returns_profile_claims_without_email_claims
    auth = build_auth(scopes: ["openid", "profile", "email"])
    cookie = sign_up_cookie(auth, name: "OAuth Profile")
    client = create_client(auth, cookie, grant_types: ["authorization_code"], response_types: ["code"], scope: "openid profile email")
    tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid profile")

    userinfo = auth.api.oauth2_user_info(headers: {"authorization" => "Bearer #{tokens[:access_token]}"})

    assert userinfo[:sub]
    assert_equal "OAuth Profile", userinfo[:name]
    assert_equal "OAuth", userinfo[:given_name]
    assert_equal "Profile", userinfo[:family_name]
    refute userinfo.key?(:email)
    refute userinfo.key?(:email_verified)
  end

  def test_userinfo_returns_email_claims_without_profile_claims
    auth = build_auth(scopes: ["openid", "profile", "email"])
    cookie = sign_up_cookie(auth, email: "userinfo-email@example.com")
    client = create_client(auth, cookie, grant_types: ["authorization_code"], response_types: ["code"], scope: "openid profile email")
    tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid email")

    userinfo = auth.api.oauth2_user_info(headers: {"authorization" => "Bearer #{tokens[:access_token]}"})

    assert userinfo[:sub]
    assert_equal "userinfo-email@example.com", userinfo[:email]
    assert_equal false, userinfo[:email_verified]
    refute userinfo.key?(:name)
    refute userinfo.key?(:given_name)
    refute userinfo.key?(:family_name)
  end

  def test_userinfo_file_parity_filters_profile_and_email_claims_by_scope
    auth = build_auth(scopes: ["openid", "profile", "email"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid profile email", skip_consent: true)

    openid = issue_authorization_code_tokens(auth, cookie, client, scope: "openid")
    profile = issue_authorization_code_tokens(auth, cookie, client, scope: "openid profile")
    email = issue_authorization_code_tokens(auth, cookie, client, scope: "openid email")

    openid_info = auth.api.oauth2_user_info(headers: {"authorization" => "Bearer #{openid[:access_token]}"})
    profile_info = auth.api.oauth2_user_info(headers: {"authorization" => "Bearer #{profile[:access_token]}"})
    email_info = auth.api.oauth2_user_info(headers: {"authorization" => "Bearer #{email[:access_token]}"})

    assert openid_info[:sub]
    refute openid_info.key?(:name)
    assert_equal "OAuth Owner", profile_info[:name]
    refute profile_info.key?(:email)
    assert_equal "oauth-provider@example.com", email_info[:email]
    refute email_info.key?(:name)
  end
end
