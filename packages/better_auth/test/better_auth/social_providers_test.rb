# frozen_string_literal: true

require "uri"
require "openssl"
require_relative "../test_helper"

class BetterAuthSocialProvidersTest < Minitest::Test
  def test_google_authorization_url_shape
    provider = BetterAuth::SocialProviders.google(client_id: "google-id", client_secret: "google-secret")

    url = provider.fetch(:create_authorization_url).call(
      state: "state-1",
      code_verifier: "verifier-1",
      redirect_uri: "http://localhost:3000/api/auth/callback/google",
      scopes: ["openid", "email", "profile"],
      loginHint: "ada@example.com"
    )

    assert_equal "google", provider.fetch(:id)
    assert_includes url, "https://accounts.google.com/o/oauth2/v2/auth"
    assert_includes url, "client_id=google-id"
    assert_includes url, "scope=openid+email+profile"
    assert_includes url, "state=state-1"
    assert_includes url, "code_challenge="
    assert_includes url, "code_challenge_method=S256"
    assert_includes url, "login_hint=ada%40example.com"
  end

  def test_google_and_vercel_require_code_verifier_for_authorization_url
    google = BetterAuth::SocialProviders.google(client_id: "google-id", client_secret: "google-secret")
    vercel = BetterAuth::SocialProviders.vercel(client_id: "vercel-id", client_secret: "vercel-secret")

    assert_raises(BetterAuth::Error) do
      google.fetch(:create_authorization_url).call(
        state: "state-1",
        redirect_uri: "http://localhost:3000/api/auth/callback/google"
      )
    end
    assert_raises(BetterAuth::Error) do
      vercel.fetch(:create_authorization_url).call(
        state: "state-1",
        redirect_uri: "http://localhost:3000/api/auth/callback/vercel"
      )
    end
  end

  def test_upstream_pkce_required_providers_require_code_verifier_for_authorization_url
    providers = {
      atlassian: BetterAuth::SocialProviders.atlassian(client_id: "atlassian-id", client_secret: "atlassian-secret"),
      figma: BetterAuth::SocialProviders.figma(client_id: "figma-id", client_secret: "figma-secret"),
      paybin: BetterAuth::SocialProviders.paybin(client_id: "paybin-id", client_secret: "paybin-secret"),
      salesforce: BetterAuth::SocialProviders.salesforce(client_id: "salesforce-id", client_secret: "salesforce-secret")
    }

    providers.each do |name, provider|
      error = assert_raises(BetterAuth::Error) do
        provider.fetch(:create_authorization_url).call(
          state: "state-1",
          redirect_uri: "http://localhost:3000/api/auth/callback/#{name}"
        )
      end
      assert_match(/codeVerifier is required/i, error.message)
    end
  end

  def test_google_uses_first_configured_client_id_for_authorization_url
    provider = BetterAuth::SocialProviders.google(client_id: ["web-id", "ios-id"], client_secret: "google-secret")

    url = provider.fetch(:create_authorization_url).call(
      state: "state-1",
      code_verifier: "verifier-1",
      redirect_uri: "http://localhost:3000/api/auth/callback/google"
    )

    assert_includes url, "client_id=web-id"
    refute_includes url, "ios-id"
  end

  def test_apple_uses_first_configured_client_id_for_authorization_url
    provider = BetterAuth::SocialProviders.apple(client_id: ["web-id", "ios-id"], client_secret: "apple-secret")

    url = provider.fetch(:create_authorization_url).call(
      state: "state-1",
      redirect_uri: "http://localhost:3000/api/auth/callback/apple"
    )

    assert_includes url, "client_id=web-id"
    refute_includes url, "ios-id"
  end

  def test_widened_multi_client_id_providers_use_first_entry_for_authorization_url
    providers = [
      BetterAuth::SocialProviders.facebook(client_id: ["fb-web", "fb-mobile"], client_secret: "facebook-secret"),
      BetterAuth::SocialProviders.cognito(
        client_id: ["cog-web", "cog-mobile"],
        client_secret: "cognito-secret",
        domain: "cognito.example",
        region: "us-east-1",
        user_pool_id: "pool-1"
      )
    ]

    providers.each do |provider|
      url = provider.fetch(:create_authorization_url).call(
        state: "state-1",
        code_verifier: "verifier-1",
        redirect_uri: "http://localhost:3000/api/auth/callback/#{provider.fetch(:id)}"
      )

      client_id = Rack::Utils.parse_query(URI.parse(url).query).fetch("client_id")
      expected_client_id = (provider.fetch(:id) == "facebook") ? "fb-web" : "cog-web"
      assert_equal expected_client_id, client_id
    end
  end

  def test_empty_client_id_array_is_rejected_for_widened_providers
    [
      -> { BetterAuth::SocialProviders.google(client_id: [], client_secret: "secret") },
      -> { BetterAuth::SocialProviders.apple(client_id: [], client_secret: "secret") },
      -> { BetterAuth::SocialProviders.facebook(client_id: [], client_secret: "secret").fetch(:create_authorization_url).call(state: "state") },
      -> {
        BetterAuth::SocialProviders.cognito(
          client_id: [],
          client_secret: "secret",
          domain: "cognito.example",
          region: "us-east-1",
          user_pool_id: "pool-1"
        ).fetch(:create_authorization_url).call(state: "state")
      }
    ].each do |factory|
      error = assert_raises(BetterAuth::Error) { factory.call }
      assert_equal "CLIENT_ID_AND_SECRET_REQUIRED", error.message
    end
  end

  def test_google_id_token_verifier_rejects_unconfigured_audience
    key = OpenSSL::PKey::RSA.generate(2048)
    jwks = {"keys" => [rsa_public_jwk(key, "google-kid")]}
    provider = BetterAuth::SocialProviders.google(client_id: ["web-id", "ios-id"], client_secret: "google-secret", jwks: jwks)

    assert provider.fetch(:verify_id_token).call(signed_jwt(key, "google-kid", "iss" => "https://accounts.google.com", "aud" => "ios-id", "sub" => "sub-1"))
    refute provider.fetch(:verify_id_token).call(signed_jwt(key, "google-kid", "iss" => "https://accounts.google.com", "aud" => "android-id", "sub" => "sub-1"))
    refute provider.fetch(:verify_id_token).call(fake_jwt("iss" => "https://accounts.google.com", "aud" => "ios-id", "sub" => "sub-1"))
  end

  def test_google_id_token_verifier_enforces_hosted_domain_restrictions
    key = OpenSSL::PKey::RSA.generate(2048)
    jwks = {"keys" => [rsa_public_jwk(key, "google-hd-kid")]}
    claims = {"iss" => "https://accounts.google.com", "aud" => "google-id", "sub" => "google-sub"}
    workspace_token = signed_jwt(key, "google-hd-kid", claims.merge("hd" => "example.com"))
    other_workspace_token = signed_jwt(key, "google-hd-kid", claims.merge("hd" => "other.com"))
    consumer_token = signed_jwt(key, "google-hd-kid", claims)

    exact = BetterAuth::SocialProviders.google(client_id: "google-id", client_secret: "google-secret", hd: "example.com", jwks: jwks)
    wildcard = BetterAuth::SocialProviders.google(client_id: "google-id", client_secret: "google-secret", hd: "*", jwks: jwks)
    unrestricted = BetterAuth::SocialProviders.google(client_id: "google-id", client_secret: "google-secret", jwks: jwks)

    assert exact.fetch(:verify_id_token).call(workspace_token)
    refute exact.fetch(:verify_id_token).call(other_workspace_token)
    refute exact.fetch(:verify_id_token).call(consumer_token)
    assert wildcard.fetch(:verify_id_token).call(workspace_token)
    refute wildcard.fetch(:verify_id_token).call(consumer_token)
    assert unrestricted.fetch(:verify_id_token).call(consumer_token)
  end

  def test_google_profile_path_enforces_hosted_domain_restrictions
    profile = {
      "sub" => "google-sub",
      "name" => "Workspace User",
      "email" => "workspace@example.com",
      "email_verified" => true
    }
    workspace_token = unsigned_jwt(profile.merge("hd" => "example.com"))
    other_workspace_token = unsigned_jwt(profile.merge("hd" => "other.com"))
    consumer_token = unsigned_jwt(profile)

    exact = BetterAuth::SocialProviders.google(client_id: "google-id", client_secret: "google-secret", hd: "example.com")
    wildcard = BetterAuth::SocialProviders.google(client_id: "google-id", client_secret: "google-secret", hd: "*")
    unrestricted = BetterAuth::SocialProviders.google(client_id: "google-id", client_secret: "google-secret")

    assert_equal "workspace@example.com", exact.fetch(:get_user_info).call(idToken: workspace_token).fetch(:user).fetch(:email)
    assert_nil exact.fetch(:get_user_info).call(idToken: other_workspace_token)
    assert_nil exact.fetch(:get_user_info).call(idToken: consumer_token)
    assert_equal "workspace@example.com", wildcard.fetch(:get_user_info).call(idToken: workspace_token).fetch(:user).fetch(:email)
    assert_nil wildcard.fetch(:get_user_info).call(idToken: consumer_token)
    assert_equal "workspace@example.com", unrestricted.fetch(:get_user_info).call(idToken: consumer_token).fetch(:user).fetch(:email)
  end

  def test_id_token_jwks_timeout_returns_invalid_token_result
    provider = BetterAuth::SocialProviders.google(
      client_id: "google-id",
      client_secret: "google-secret",
      jwks_endpoint: "https://issuer.example/jwks"
    )

    Net::HTTP.stub(:start, ->(*_args, **_kwargs) { raise Net::OpenTimeout }) do
      refute provider.fetch(:verify_id_token).call(fake_jwt("iss" => "https://accounts.google.com", "aud" => "google-id", "sub" => "sub-1"))
    end
  end

  def test_apple_id_token_verifier_uses_jwks_and_audience_override
    key = OpenSSL::PKey::RSA.generate(2048)
    provider = BetterAuth::SocialProviders.apple(
      client_id: "web-id",
      client_secret: "apple-secret",
      audience: "bundle-id",
      jwks: {"keys" => [rsa_public_jwk(key, "apple-kid")]}
    )

    assert provider.fetch(:verify_id_token).call(signed_jwt(key, "apple-kid", "iss" => "https://appleid.apple.com", "aud" => "bundle-id", "sub" => "apple-sub"))
    refute provider.fetch(:verify_id_token).call(signed_jwt(key, "apple-kid", "iss" => "https://appleid.apple.com", "aud" => "web-id", "sub" => "apple-sub"))
  end

  def test_microsoft_id_token_verifier_validates_specific_tenant_issuer
    key = OpenSSL::PKey::RSA.generate(2048)
    provider = BetterAuth::SocialProviders.microsoft(
      client_id: "microsoft-id",
      tenant_id: "tenant-1",
      jwks: {"keys" => [rsa_public_jwk(key, "microsoft-kid")]}
    )

    assert provider.fetch(:verify_id_token).call(signed_jwt(key, "microsoft-kid", "iss" => "https://login.microsoftonline.com/tenant-1/v2.0", "aud" => "microsoft-id", "sub" => "ms-sub", "tid" => "tenant-1"))
    refute provider.fetch(:verify_id_token).call(signed_jwt(key, "microsoft-kid", "iss" => "https://login.microsoftonline.com/other/v2.0", "aud" => "microsoft-id", "sub" => "ms-sub", "tid" => "tenant-1"))
  end

  def test_microsoft_id_token_verifier_enforces_organization_tenant_class
    key = OpenSSL::PKey::RSA.generate(2048)
    provider = microsoft_provider_for_test(key, tenant_id: "organizations")

    assert provider.fetch(:verify_id_token).call(microsoft_token(key, tid: microsoft_work_tenant_id))
    refute provider.fetch(:verify_id_token).call(microsoft_token(key, tid: microsoft_consumer_tenant_id))
  end

  def test_microsoft_id_token_verifier_enforces_consumer_tenant_class
    key = OpenSSL::PKey::RSA.generate(2048)
    provider = microsoft_provider_for_test(key, tenant_id: "consumers")

    assert provider.fetch(:verify_id_token).call(microsoft_token(key, tid: microsoft_consumer_tenant_id))
    refute provider.fetch(:verify_id_token).call(microsoft_token(key, tid: microsoft_work_tenant_id))
  end

  def test_microsoft_id_token_verifier_common_accepts_work_and_consumer_tenants
    key = OpenSSL::PKey::RSA.generate(2048)
    provider = microsoft_provider_for_test(key, tenant_id: "common")

    assert provider.fetch(:verify_id_token).call(microsoft_token(key, tid: microsoft_work_tenant_id))
    assert provider.fetch(:verify_id_token).call(microsoft_token(key, tid: microsoft_consumer_tenant_id))
  end

  def test_microsoft_id_token_verifier_rejects_missing_or_non_string_tenant_id
    key = OpenSSL::PKey::RSA.generate(2048)
    provider = microsoft_provider_for_test(key, tenant_id: "common")
    issuer = "https://login.microsoftonline.com/#{microsoft_work_tenant_id}/v2.0"

    refute provider.fetch(:verify_id_token).call(signed_jwt(key, "microsoft-tenant-kid", "iss" => issuer, "aud" => "microsoft-id", "sub" => "ms-sub"))
    refute provider.fetch(:verify_id_token).call(signed_jwt(key, "microsoft-tenant-kid", "iss" => issuer, "aud" => "microsoft-id", "sub" => "ms-sub", "tid" => 123))
  end

  def test_microsoft_id_token_verifier_binds_issuer_to_tenant_id
    key = OpenSSL::PKey::RSA.generate(2048)
    provider = microsoft_provider_for_test(key, tenant_id: "common")
    token = microsoft_token(
      key,
      tid: microsoft_work_tenant_id,
      issuer: "https://login.microsoftonline.com/#{microsoft_consumer_tenant_id}/v2.0"
    )

    refute provider.fetch(:verify_id_token).call(token)
  end

  def test_microsoft_id_token_verifier_normalizes_custom_authority_and_binds_issuer
    key = OpenSSL::PKey::RSA.generate(2048)
    provider = microsoft_provider_for_test(key, tenant_id: "common", authority: "https://login.example.test/")
    valid = microsoft_token(key, tid: microsoft_work_tenant_id, authority: "https://login.example.test")
    wrong_authority = microsoft_token(key, tid: microsoft_work_tenant_id)

    assert provider.fetch(:verify_id_token).call(valid)
    refute provider.fetch(:verify_id_token).call(wrong_authority)
  end

  def test_facebook_default_id_token_verifier_validates_limited_login_jwt
    key = OpenSSL::PKey::RSA.generate(2048)
    provider = BetterAuth::SocialProviders.facebook(
      client_id: "facebook-id",
      client_secret: "facebook-secret",
      jwks: {"keys" => [rsa_public_jwk(key, "facebook-kid")]}
    )

    assert provider.fetch(:verify_id_token).call(
      signed_jwt(key, "facebook-kid", "iss" => "https://www.facebook.com", "aud" => "facebook-id", "sub" => "fb-sub", "nonce" => "nonce-1"),
      "nonce-1"
    )
    refute provider.fetch(:verify_id_token).call(signed_jwt(key, "facebook-kid", "iss" => "https://www.facebook.com", "aud" => "other-id", "sub" => "fb-sub"))
    refute BetterAuth::SocialProviders.facebook(client_id: "facebook-id", client_secret: "facebook-secret", disable_id_token_sign_in: true)
      .fetch(:verify_id_token).call("opaque-access-token")
  end

  def test_facebook_opaque_token_verifier_requires_debug_token_app_binding
    captured_urls = []
    get_json = lambda do |url, _headers = {}|
      captured_urls << url
      {"data" => {"is_valid" => true, "app_id" => "facebook-id", "user_id" => "fb-user"}}
    end
    provider = BetterAuth::SocialProviders.facebook(client_id: "facebook-id", client_secret: "facebook-secret")

    BetterAuth::SocialProviders::Base.stub(:get_json, get_json) do
      assert provider.fetch(:verify_id_token).call("opaque-access-token")
    end

    refute_empty captured_urls
    debug_params = auth_params(captured_urls.fetch(0))
    assert_includes captured_urls.fetch(0), "https://graph.facebook.com/debug_token"
    assert_equal "opaque-access-token", debug_params.fetch("input_token")
    assert_equal "facebook-id|facebook-secret", debug_params.fetch("access_token")
  end

  def test_facebook_opaque_token_verifier_rejects_wrong_app_and_invalid_token
    provider = BetterAuth::SocialProviders.facebook(client_id: "facebook-id", client_secret: "facebook-secret")
    responses = [
      {"data" => {"is_valid" => true, "app_id" => "other-app", "user_id" => "fb-user"}},
      {"data" => {"is_valid" => false, "app_id" => "facebook-id", "user_id" => "fb-user"}}
    ]

    BetterAuth::SocialProviders::Base.stub(:get_json, ->(_url, _headers = {}) { responses.shift }) do
      refute provider.fetch(:verify_id_token).call("wrong-app-token")
      refute provider.fetch(:verify_id_token).call("revoked-token")
    end
  end

  def test_facebook_opaque_token_verifier_rejects_missing_client_secret
    provider = BetterAuth::SocialProviders.facebook(client_id: "facebook-id", client_secret: "")
    get_json = ->(_url, _headers = {}) { flunk "Facebook should not inspect a token without an app secret" }

    BetterAuth::SocialProviders::Base.stub(:get_json, get_json) do
      refute provider.fetch(:verify_id_token).call("opaque-access-token")
    end
  end

  def test_facebook_opaque_profile_requires_debug_token_subject_match
    provider = BetterAuth::SocialProviders.facebook(client_id: "facebook-id", client_secret: "facebook-secret")
    get_json = lambda do |url, _headers = {}|
      if url.include?("debug_token")
        {"data" => {"is_valid" => true, "app_id" => "facebook-id", "user_id" => "bound-user"}}
      else
        facebook_profile("different-user")
      end
    end

    BetterAuth::SocialProviders::Base.stub(:get_json, get_json) do
      assert_nil_user_info provider, accessToken: "opaque-access-token"
    end
  end

  def test_facebook_opaque_profile_requires_access_token
    provider = BetterAuth::SocialProviders.facebook(client_id: "facebook-id", client_secret: "facebook-secret")
    get_json = ->(_url, _headers = {}) { flunk "Facebook should not fetch a profile without an access token" }

    BetterAuth::SocialProviders::Base.stub(:get_json, get_json) do
      assert_nil_user_info provider, {}
    end
  end

  def test_cognito_default_id_token_verifier_validates_issuer_audience_and_nonce
    key = OpenSSL::PKey::RSA.generate(2048)
    provider = BetterAuth::SocialProviders.cognito(
      client_id: "cognito-id",
      client_secret: "cognito-secret",
      domain: "tenant.auth.us-east-1.amazoncognito.com",
      region: "us-east-1",
      user_pool_id: "pool-1",
      jwks: {"keys" => [rsa_public_jwk(key, "cognito-kid")]}
    )

    token = signed_jwt(
      key,
      "cognito-kid",
      "iss" => "https://cognito-idp.us-east-1.amazonaws.com/pool-1",
      "aud" => "cognito-id",
      "sub" => "cognito-sub",
      "nonce" => "nonce-1"
    )

    assert provider.fetch(:verify_id_token).call(token, "nonce-1")
    refute provider.fetch(:verify_id_token).call(token, "other-nonce")
    refute BetterAuth::SocialProviders.cognito(
      client_id: "cognito-id",
      domain: "tenant.auth.us-east-1.amazoncognito.com",
      region: "us-east-1",
      user_pool_id: "pool-1",
      disable_id_token_sign_in: true
    ).fetch(:verify_id_token).call(token)
  end

  def test_line_default_id_token_verifier_posts_to_verify_endpoint
    captured = nil
    post_form = lambda do |url, form, headers = {}|
      captured = {url: url, form: form, headers: headers}
      {"aud" => "line-id", "sub" => "line-sub", "nonce" => "nonce-1"}
    end
    provider = BetterAuth::SocialProviders.line(client_id: "line-id", client_secret: "line-secret")

    result = nil
    BetterAuth::SocialProviders::Base.stub(:post_form_json, post_form) do
      result = provider.fetch(:verify_id_token).call("line-id-token", "nonce-1")
    end

    assert_equal true, result
    assert_equal "https://api.line.me/oauth2/v2.1/verify", captured.fetch(:url)
    assert_equal "line-id-token", captured.fetch(:form).fetch(:id_token)
    assert_equal "line-id", captured.fetch(:form).fetch(:client_id)
    assert_equal "nonce-1", captured.fetch(:form).fetch(:nonce)
    refute BetterAuth::SocialProviders.line(client_id: "line-id", client_secret: "line-secret", disable_id_token_sign_in: true)
      .fetch(:verify_id_token).call("line-id-token")
  end

  def test_paypal_id_token_verifier_accepts_rs256
    key = OpenSSL::PKey::RSA.generate(2048)
    provider = paypal_provider(jwks: {"keys" => [rsa_public_jwk(key, "paypal-kid")]})
    token = signed_jwt(key, "paypal-kid", paypal_id_token_claims)

    assert provider.fetch(:verify_id_token).call(token, "nonce-1")
  end

  def test_paypal_id_token_verifier_accepts_hs256
    provider = paypal_provider
    token = algorithm_jwt("paypal-secret", "HS256", paypal_id_token_claims)

    assert provider.fetch(:verify_id_token).call(token, "nonce-1")
  end

  def test_paypal_id_token_verifier_rejects_wrong_signature
    trusted_key = OpenSSL::PKey::RSA.generate(2048)
    attacker_key = OpenSSL::PKey::RSA.generate(2048)
    provider = paypal_provider(jwks: {"keys" => [rsa_public_jwk(trusted_key, "paypal-kid")]})
    token = signed_jwt(attacker_key, "paypal-kid", paypal_id_token_claims)

    refute provider.fetch(:verify_id_token).call(token, "nonce-1")
  end

  def test_paypal_id_token_verifier_rejects_unsupported_algorithm
    provider = paypal_provider
    token = algorithm_jwt("paypal-secret", "HS384", paypal_id_token_claims)

    refute provider.fetch(:verify_id_token).call(token, "nonce-1")
  end

  def test_paypal_id_token_verifier_rejects_wrong_issuer
    provider = paypal_provider
    token = algorithm_jwt("paypal-secret", "HS256", paypal_id_token_claims.merge("iss" => "https://attacker.example"))

    refute provider.fetch(:verify_id_token).call(token, "nonce-1")
  end

  def test_paypal_id_token_verifier_rejects_wrong_audience
    provider = paypal_provider
    token = algorithm_jwt("paypal-secret", "HS256", paypal_id_token_claims.merge("aud" => "other-client"))

    refute provider.fetch(:verify_id_token).call(token, "nonce-1")
  end

  def test_paypal_id_token_verifier_rejects_wrong_nonce
    provider = paypal_provider
    token = algorithm_jwt("paypal-secret", "HS256", paypal_id_token_claims)

    refute provider.fetch(:verify_id_token).call(token, "other-nonce")
  end

  def test_paypal_id_token_verifier_honors_disable_flag
    provider = paypal_provider(disable_id_token_sign_in: true)
    token = algorithm_jwt("paypal-secret", "HS256", paypal_id_token_claims)

    refute provider.fetch(:verify_id_token).call(token, "nonce-1")
  end

  def test_paypal_user_info_matches_id_token_subject_and_keeps_user_id
    provider = paypal_provider
    token = algorithm_jwt("paypal-secret", "HS256", paypal_id_token_claims("sub" => "paypal-subject"))
    profile = paypal_profile("user_id" => "paypal-account", "sub" => "paypal-subject")

    BetterAuth::SocialProviders::Base.stub(:get_json, ->(_url, _headers = {}) { profile }) do
      info = provider.fetch(:get_user_info).call(accessToken: "paypal-access", idToken: token)

      assert_equal "paypal-account", info.fetch(:user).fetch(:id)
    end
  end

  def test_paypal_user_info_rejects_mismatched_id_token_subject
    provider = paypal_provider
    token = algorithm_jwt("paypal-secret", "HS256", paypal_id_token_claims("sub" => "other-subject"))

    BetterAuth::SocialProviders::Base.stub(:get_json, ->(_url, _headers = {}) { paypal_profile("user_id" => "paypal-account") }) do
      assert_nil_user_info provider, accessToken: "paypal-access", idToken: token
    end
  end

  def test_paypal_user_info_prefers_profile_subject_for_matching
    provider = paypal_provider
    token = algorithm_jwt("paypal-secret", "HS256", paypal_id_token_claims("sub" => "paypal-account"))
    profile = paypal_profile("user_id" => "paypal-account", "sub" => "different-subject")

    BetterAuth::SocialProviders::Base.stub(:get_json, ->(_url, _headers = {}) { profile }) do
      assert_nil_user_info provider, accessToken: "paypal-access", idToken: token
    end
  end

  def test_cognito_requires_hosted_domain_options_and_encodes_scope_with_percent_twenty
    assert_raises(BetterAuth::Error) do
      BetterAuth::SocialProviders.cognito(client_id: "cognito-id")
    end

    provider = BetterAuth::SocialProviders.cognito(
      client_id: "cognito-id",
      domain: "https://tenant.auth.us-east-1.amazoncognito.com/",
      region: "us-east-1",
      userPoolId: "pool-1"
    )
    url = provider.fetch(:create_authorization_url).call(
      state: "state-1",
      code_verifier: "verifier-1",
      redirect_uri: "http://localhost:3000/api/auth/callback/cognito"
    )

    assert_includes url, "https://tenant.auth.us-east-1.amazoncognito.com/oauth2/authorize"
    assert_includes url, "scope=openid%20profile%20email"
    refute_includes url, "scope=openid+profile+email"
  end

  def test_cognito_requires_client_secret_when_requested
    assert_raises(BetterAuth::Error) do
      BetterAuth::SocialProviders.cognito(
        client_id: "cognito-id",
        domain: "tenant.auth.us-east-1.amazoncognito.com",
        region: "us-east-1",
        user_pool_id: "pool-1",
        requireClientSecret: true
      )
    end
  end

  def test_cognito_get_user_info_prefers_id_token_and_falls_back_to_userinfo
    provider = BetterAuth::SocialProviders.cognito(
      client_id: "cognito-id",
      domain: "tenant.auth.us-east-1.amazoncognito.com",
      region: "us-east-1",
      user_pool_id: "pool-1"
    )

    token_info = provider.fetch(:get_user_info).call(
      idToken: unsigned_jwt("sub" => "cognito-sub", "email" => "cognito@example.com", "given_name" => "Cognito", "email_verified" => true)
    )

    assert_equal "Cognito", token_info.fetch(:user).fetch(:name)
    assert_equal "cognito@example.com", token_info.fetch(:user).fetch(:email)

    captured = nil
    get_json = lambda do |url, headers = {}|
      captured = {url: url, headers: headers}
      {"sub" => "fallback-sub", "email" => "fallback@example.com", "username" => "fallback", "email_verified" => false}
    end
    fallback_info = nil
    BetterAuth::SocialProviders::Base.stub(:get_json, get_json) do
      fallback_info = provider.fetch(:get_user_info).call(accessToken: "cognito-access")
    end

    assert_equal "https://tenant.auth.us-east-1.amazoncognito.com/oauth2/userinfo", captured.fetch(:url)
    assert_equal "Bearer cognito-access", captured.fetch(:headers).fetch("Authorization")
    assert_equal "fallback", fallback_info.fetch(:user).fetch(:name)
  end

  def test_twitter_fetches_profile_and_confirmed_email_separately
    captured_urls = []
    get_json = lambda do |url, _headers = {}|
      captured_urls << url
      if url.include?("confirmed_email")
        {"data" => {"confirmed_email" => "twitter@example.com"}}
      else
        {"data" => {"id" => "twitter-id", "name" => "Twitter User", "username" => "twitter", "profile_image_url" => "https://x.example/avatar.png"}}
      end
    end
    provider = BetterAuth::SocialProviders.twitter(client_id: "twitter-id", client_secret: "twitter-secret")
    info = nil

    BetterAuth::SocialProviders::Base.stub(:get_json, get_json) do
      info = provider.fetch(:get_user_info).call(accessToken: "twitter-access")
    end

    assert_equal [
      "https://api.x.com/2/users/me?user.fields=profile_image_url",
      "https://api.x.com/2/users/me?user.fields=confirmed_email"
    ], captured_urls
    assert_equal "twitter@example.com", info.fetch(:user).fetch(:email)
    assert_equal true, info.fetch(:user).fetch(:emailVerified)
  end

  def test_vk_posts_userinfo_form_without_bearer_and_requires_email
    captured = nil
    post_json = lambda do |url, body = {}, headers = {}|
      captured = {url: url, body: body, headers: headers}
      {"user" => {"user_id" => "vk-id", "first_name" => "VK", "last_name" => "User", "email" => "vk@example.com", "avatar" => "https://vk.example/avatar.png"}}
    end
    provider = BetterAuth::SocialProviders.vk(client_id: "vk-id", client_secret: "vk-secret")
    info = nil

    BetterAuth::SocialProviders::Base.stub(:post_json, post_json) do
      info = provider.fetch(:get_user_info).call(accessToken: "vk-access")
    end

    assert_equal "https://id.vk.com/oauth2/user_info", captured.fetch(:url)
    assert_equal "vk-access", captured.fetch(:body).fetch(:access_token)
    assert_equal "vk-id", captured.fetch(:body).fetch(:client_id)
    refute captured.fetch(:headers).key?("Authorization")
    assert_equal "vk@example.com", info.fetch(:user).fetch(:email)

    BetterAuth::SocialProviders::Base.stub(:post_json, ->(_url, _body = {}, _headers = {}) { {"user" => {"user_id" => "vk-id", "first_name" => "VK", "last_name" => "User"}} }) do
      assert_nil_user_info provider, accessToken: "vk-access"
    end
  end

  def test_paybin_returns_nil_without_id_token
    provider = BetterAuth::SocialProviders.paybin(client_id: "paybin-id", client_secret: "paybin-secret")

    assert_nil_user_info provider, accessToken: "paybin-access"
  end

  def test_paypal_token_exchange_normalizes_id_token
    captured, post_form = capture_post_form({"access_token" => "paypal-access", "refresh_token" => "paypal-refresh", "id_token" => "paypal-id-token", "expires_in" => 60})
    provider = BetterAuth::SocialProviders.paypal(client_id: "paypal-id", client_secret: "paypal-secret")
    tokens = nil

    BetterAuth::SocialProviders::Base.stub(:post_form_json, post_form) do
      tokens = provider.fetch(:validate_authorization_code).call(code: "code-1", redirect_uri: "http://localhost:3000/api/auth/callback/paypal")
    end

    assert_basic_token_request captured.fetch(0), "paypal-id", "paypal-secret"
    assert_equal "paypal-id-token", tokens.fetch("idToken")
    assert_equal "paypal-access", tokens.fetch("accessToken")
  end

  def test_paypal_refresh_access_token_preserves_accept_language
    captured, post_form = capture_post_form({"access_token" => "paypal-access"})
    provider = BetterAuth::SocialProviders.paypal(client_id: "paypal-id", client_secret: "paypal-secret")

    BetterAuth::SocialProviders::Base.stub(:post_form_json, post_form) do
      provider.fetch(:refresh_access_token).call("paypal-refresh")
    end

    assert_basic_token_request captured.fetch(0), "paypal-id", "paypal-secret"
    assert_equal "en_US", captured.fetch(0).fetch(:headers).fetch("Accept-Language")
    assert_equal "refresh_token", captured.fetch(0).fetch(:form).fetch(:grant_type)
  end

  def test_reddit_authorization_code_exchange_uses_upstream_headers
    captured, post_form = capture_post_form({"access_token" => "reddit-access"})
    provider = BetterAuth::SocialProviders.reddit(client_id: "reddit-id", client_secret: "reddit-secret")

    BetterAuth::SocialProviders::Base.stub(:post_form_json, post_form) do
      provider.fetch(:validate_authorization_code).call(
        code: "code-1",
        redirect_uri: "http://localhost:3000/api/auth/callback/reddit"
      )
    end

    assert_basic_token_request captured.fetch(0), "reddit-id", "reddit-secret"
    assert_equal "text/plain", captured.fetch(0).fetch(:headers).fetch("accept")
    assert_equal "better-auth", captured.fetch(0).fetch(:headers).fetch("user-agent")
    assert_equal "authorization_code", captured.fetch(0).fetch(:form).fetch(:grant_type)
  end

  def test_reddit_uses_distinct_unverified_placeholder_emails_per_profile
    provider = BetterAuth::SocialProviders.reddit(client_id: "reddit-app", client_secret: "reddit-secret")
    profiles = [
      reddit_profile("user-a", oauth_client_id: "shared-client"),
      reddit_profile("user-b", oauth_client_id: "shared-client")
    ]

    BetterAuth::SocialProviders::Base.stub(:get_json, ->(_url, _headers = {}) { profiles.shift }) do
      first = provider.fetch(:get_user_info).call(accessToken: "reddit-token-a")
      second = provider.fetch(:get_user_info).call(accessToken: "reddit-token-b")

      assert_equal "user-a@reddit.invalid", first.fetch(:user).fetch(:email)
      assert_equal "user-b@reddit.invalid", second.fetch(:user).fetch(:email)
      refute first.fetch(:user).fetch(:emailVerified)
      refute second.fetch(:user).fetch(:emailVerified)
    end
  end

  def test_reddit_profile_mapping_can_override_placeholder_email_and_verification
    provider = BetterAuth::SocialProviders.reddit(
      client_id: "reddit-app",
      client_secret: "reddit-secret",
      map_profile_to_user: ->(_profile) { {email: "real@example.com", emailVerified: true} }
    )

    BetterAuth::SocialProviders::Base.stub(:get_json, ->(_url, _headers = {}) { reddit_profile("mapped-user") }) do
      info = provider.fetch(:get_user_info).call(accessToken: "reddit-token")

      assert_equal "real@example.com", info.fetch(:user).fetch(:email)
      assert info.fetch(:user).fetch(:emailVerified)
    end
  end

  def test_remaining_provider_authorization_url_contracts
    dropbox = auth_params(BetterAuth::SocialProviders.dropbox(client_id: "dropbox-id", client_secret: "dropbox-secret", access_type: "offline").fetch(:create_authorization_url).call(state: "state-1", code_verifier: "verifier-1", redirect_uri: "http://localhost/dropbox"))
    assert_equal "offline", dropbox.fetch("token_access_type")
    assert_equal "S256", dropbox.fetch("code_challenge_method")

    gitlab_url = BetterAuth::SocialProviders.gitlab(client_id: "gitlab-id", client_secret: "gitlab-secret", issuer: "https://gitlab.example/").fetch(:create_authorization_url).call(state: "state-1", redirect_uri: "http://localhost/gitlab", loginHint: "gitlab@example.com")
    assert_includes gitlab_url, "https://gitlab.example/oauth/authorize"
    assert_equal "gitlab@example.com", auth_params(gitlab_url).fetch("login_hint")

    polar = auth_params(BetterAuth::SocialProviders.polar(client_id: "polar-id", client_secret: "polar-secret", prompt: "consent").fetch(:create_authorization_url).call(state: "state-1", code_verifier: "verifier-1", redirect_uri: "http://localhost/polar"))
    assert_equal "consent", polar.fetch("prompt")
    assert_equal "S256", polar.fetch("code_challenge_method")

    roblox = auth_params(BetterAuth::SocialProviders.roblox(client_id: "roblox-id", client_secret: "roblox-secret").fetch(:create_authorization_url).call(state: "state-1", redirect_uri: "http://localhost/roblox"))
    assert_equal "select_account consent", roblox.fetch("prompt")

    tiktok = auth_params(BetterAuth::SocialProviders.tiktok(client_id: "client-id", client_secret: "tiktok-secret", client_key: "client-key").fetch(:create_authorization_url).call(state: "state-1", redirect_uri: "http://localhost/tiktok", scopes: ["user.info.basic"]))
    assert_equal "client-key", tiktok.fetch("client_key")
    assert_equal "user.info.profile,user.info.basic", tiktok.fetch("scope")

    twitch = auth_params(BetterAuth::SocialProviders.twitch(client_id: "twitch-id", client_secret: "twitch-secret").fetch(:create_authorization_url).call(state: "state-1", redirect_uri: "http://localhost/twitch"))
    assert_includes twitch.fetch("claims"), "email_verified"

    paybin = auth_params(BetterAuth::SocialProviders.paybin(client_id: "paybin-id", client_secret: "paybin-secret", prompt: "consent").fetch(:create_authorization_url).call(state: "state-1", code_verifier: "verifier-1", redirect_uri: "http://localhost/paybin", loginHint: "paybin@example.com"))
    assert_equal "consent", paybin.fetch("prompt")
    assert_equal "paybin@example.com", paybin.fetch("login_hint")

    zoom_default = auth_params(BetterAuth::SocialProviders.zoom(client_id: "zoom-id", client_secret: "zoom-secret").fetch(:create_authorization_url).call(state: "state-1", code_verifier: "verifier-1", redirect_uri: "http://localhost/zoom"))
    assert_equal "S256", zoom_default.fetch("code_challenge_method")
    zoom_without_pkce = auth_params(BetterAuth::SocialProviders.zoom(client_id: "zoom-id", client_secret: "zoom-secret", pkce: false).fetch(:create_authorization_url).call(state: "state-1", code_verifier: "verifier-1", redirect_uri: "http://localhost/zoom"))
    refute zoom_without_pkce.key?("code_challenge")
  end

  def test_remaining_provider_profile_mapping_contracts
    profile_cases = {
      atlassian: [
        BetterAuth::SocialProviders.atlassian(client_id: "id", client_secret: "secret", get_user_info: ->(_tokens) { {"account_id" => "atl-id", "name" => "Atlassian User", "email" => "atl@example.com", "picture" => "atl.png"} }),
        "Atlassian User",
        "atl@example.com"
      ],
      dropbox: [
        BetterAuth::SocialProviders.dropbox(client_id: "id", client_secret: "secret", get_user_info: ->(_tokens) { {"account_id" => "dbx-id", "name" => {"display_name" => "Dropbox User"}, "email" => "dbx@example.com", "email_verified" => true, "profile_photo_url" => "dbx.png"} }),
        "Dropbox User",
        "dbx@example.com"
      ],
      figma: [
        BetterAuth::SocialProviders.figma(client_id: "id", client_secret: "secret", get_user_info: ->(_tokens) { {"id" => "figma-id", "handle" => "Figma User", "email" => "figma@example.com", "img_url" => "figma.png"} }),
        "Figma User",
        "figma@example.com"
      ],
      huggingface: [
        BetterAuth::SocialProviders.huggingface(client_id: "id", client_secret: "secret", get_user_info: ->(_tokens) { {"sub" => "hf-id", "preferred_username" => "hf-user", "email" => "hf@example.com", "email_verified" => true} }),
        "hf-user",
        "hf@example.com"
      ],
      kakao: [
        BetterAuth::SocialProviders.kakao(client_id: "id", client_secret: "secret", get_user_info: ->(_tokens) { {"id" => 123, "kakao_account" => {"email" => "kakao@example.com", "is_email_valid" => true, "is_email_verified" => true, "profile" => {"nickname" => "Kakao User", "profile_image_url" => "kakao.png"}}} }),
        "Kakao User",
        "kakao@example.com"
      ],
      kick: [
        BetterAuth::SocialProviders.kick(client_id: "id", client_secret: "secret", get_user_info: ->(_tokens) { {"data" => [{"user_id" => "kick-id", "name" => "Kick User", "email" => "kick@example.com", "profile_picture" => "kick.png"}]} }),
        "Kick User",
        "kick@example.com"
      ],
      linkedin: [
        BetterAuth::SocialProviders.linkedin(client_id: "id", client_secret: "secret", get_user_info: ->(_tokens) { {"sub" => "li-id", "name" => "LinkedIn User", "email" => "li@example.com", "email_verified" => true, "picture" => "li.png"} }),
        "LinkedIn User",
        "li@example.com"
      ],
      notion: [
        BetterAuth::SocialProviders.notion(client_id: "id", client_secret: "secret", get_user_info: ->(_tokens) { {"bot" => {"owner" => {"user" => {"id" => "notion-id", "name" => "Notion User", "person" => {"email" => "notion@example.com"}, "avatar_url" => "notion.png"}}}} }),
        "Notion User",
        "notion@example.com"
      ],
      polar: [
        BetterAuth::SocialProviders.polar(client_id: "id", client_secret: "secret", get_user_info: ->(_tokens) { {"id" => "polar-id", "public_name" => "Polar User", "email" => "polar@example.com", "email_verified" => true, "avatar_url" => "polar.png"} }),
        "Polar User",
        "polar@example.com"
      ],
      salesforce: [
        BetterAuth::SocialProviders.salesforce(client_id: "id", client_secret: "secret", get_user_info: ->(_tokens) { {"user_id" => "sf-id", "name" => "Salesforce User", "email" => "sf@example.com", "email_verified" => true, "photos" => {"picture" => "sf.png"}} }),
        "Salesforce User",
        "sf@example.com"
      ],
      slack: [
        BetterAuth::SocialProviders.slack(client_id: "id", client_secret: "secret", get_user_info: ->(_tokens) { {"https://slack.com/user_id" => "slack-id", "name" => "Slack User", "email" => "slack@example.com", "email_verified" => true, "picture" => "slack.png"} }),
        "Slack User",
        "slack@example.com"
      ],
      spotify: [
        BetterAuth::SocialProviders.spotify(client_id: "id", client_secret: "secret", get_user_info: ->(_tokens) { {"id" => "spotify-id", "display_name" => "Spotify User", "email" => "spotify@example.com", "images" => [{"url" => "spotify.png"}]} }),
        "Spotify User",
        "spotify@example.com"
      ],
      zoom: [
        BetterAuth::SocialProviders.zoom(client_id: "id", client_secret: "secret", get_user_info: ->(_tokens) { {"id" => "zoom-id", "display_name" => "Zoom User", "email" => "zoom@example.com", "pic_url" => "zoom.png", "verified" => true} }),
        "Zoom User",
        "zoom@example.com"
      ]
    }

    profile_cases.each do |name, (provider, expected_name, expected_email)|
      info = provider.fetch(:get_user_info).call(accessToken: "#{name}-access")
      assert_equal expected_name, info.fetch(:user).fetch(:name), "#{name} should map display name"
      assert_equal expected_email, info.fetch(:user).fetch(:email), "#{name} should map email"
    end
  end

  def test_remaining_provider_nil_and_special_profile_contracts
    linear = BetterAuth::SocialProviders.linear(client_id: "linear-id", client_secret: "linear-secret")
    BetterAuth::SocialProviders::Base.stub(:post_json, ->(_url, _body = {}, _headers = {}) {}) do
      assert_nil_user_info linear, accessToken: "linear-access"
    end

    naver = BetterAuth::SocialProviders.naver(client_id: "naver-id", client_secret: "naver-secret")
    BetterAuth::SocialProviders::Base.stub(:get_json, ->(_url, _headers = {}) { {"resultcode" => "01"} }) do
      assert_nil_user_info naver, accessToken: "naver-access"
    end
    BetterAuth::SocialProviders::Base.stub(:get_json, ->(_url, _headers = {}) { {"resultcode" => "00", "response" => {"id" => "naver-id", "nickname" => "Naver User", "email" => "naver@example.com", "profile_image" => "naver.png"}} }) do
      info = naver.fetch(:get_user_info).call(accessToken: "naver-access")
      assert_equal "Naver User", info.fetch(:user).fetch(:name)
    end

    twitch = BetterAuth::SocialProviders.twitch(client_id: "twitch-id", client_secret: "twitch-secret")
    assert_nil_user_info twitch, accessToken: "twitch-access"
    twitch_info = twitch.fetch(:get_user_info).call(idToken: unsigned_jwt("sub" => "twitch-sub", "preferred_username" => "Twitch User", "email" => "twitch@example.com", "email_verified" => true, "picture" => "twitch.png"))
    assert_equal "Twitch User", twitch_info.fetch(:user).fetch(:name)
  end

  def test_github_authorization_url_shape
    provider = BetterAuth::SocialProviders.github(client_id: "github-id", client_secret: "github-secret")

    url = provider.fetch(:create_authorization_url).call(
      state: "state-1",
      redirect_uri: "http://localhost:3000/api/auth/callback/github",
      scopes: ["user:email"]
    )

    assert_equal "github", provider.fetch(:id)
    assert_includes url, "https://github.com/login/oauth/authorize"
    assert_includes url, "client_id=github-id"
    assert_includes Rack::Utils.parse_query(URI.parse(url).query).fetch("scope").split(" "), "user:email"
  end

  def test_github_uses_endpoint_overrides_for_token_and_user_info
    captured_urls = []
    post_form = lambda do |url, _form, _headers = {}|
      captured_urls << url
      {"access_token" => "github-access"}
    end
    get_json = lambda do |url, _headers = {}|
      captured_urls << url
      if url.include?("/emails")
        [{"email" => "octo@example.com", "primary" => true, "verified" => true}]
      else
        {"id" => 123, "login" => "octo", "name" => "Octo", "email" => nil, "avatar_url" => "https://example.com/octo.png"}
      end
    end

    info = nil
    BetterAuth::SocialProviders::Base.stub(:post_form_json, post_form) do
      BetterAuth::SocialProviders::Base.stub(:get_json, get_json) do
        provider = BetterAuth::SocialProviders.github(
          client_id: "github-id",
          client_secret: "github-secret",
          token_endpoint: "https://github.test/token",
          user_info_endpoint: "https://github.test/user",
          emails_endpoint: "https://github.test/emails"
        )
        provider.fetch(:validate_authorization_code).call(code: "code", redirect_uri: "http://localhost/callback")
        info = provider.fetch(:get_user_info).call(accessToken: "github-access")
      end
    end

    assert_includes captured_urls, "https://github.test/token"
    assert_includes captured_urls, "https://github.test/user"
    assert_includes captured_urls, "https://github.test/emails"
    assert_equal "octo@example.com", info.fetch(:user).fetch(:email)
  end

  def test_github_email_fallback_leaves_email_nil_when_profile_and_emails_have_no_email
    provider = BetterAuth::SocialProviders.github(client_id: "github-id", client_secret: "github-secret")
    get_json = lambda do |url, _headers = {}|
      if url.include?("/emails")
        nil
      else
        {"id" => 123, "login" => "octo", "name" => "Octo", "email" => nil, "avatar_url" => "https://example.com/octo.png"}
      end
    end

    BetterAuth::SocialProviders::Base.stub(:get_json, get_json) do
      info = provider.fetch(:get_user_info).call(accessToken: "github-access")
      assert_nil info.fetch(:user).fetch(:email)
      refute info.fetch(:user).fetch(:emailVerified)
    end
  end

  def test_reddit_and_paypal_respect_token_endpoint_overrides
    providers = {
      reddit: BetterAuth::SocialProviders.reddit(
        client_id: "reddit-id",
        client_secret: "reddit-secret",
        token_endpoint: "https://reddit.test/token"
      ),
      paypal: BetterAuth::SocialProviders.paypal(
        client_id: "paypal-id",
        client_secret: "paypal-secret",
        tokenEndpoint: "https://paypal.test/token"
      )
    }

    providers.each do |name, provider|
      captured, post_form = capture_post_form({"access_token" => "#{name}-access"})
      BetterAuth::SocialProviders::Base.stub(:post_form_json, post_form) do
        provider.fetch(:validate_authorization_code).call(code: "code-1", redirect_uri: "http://localhost/#{name}")
        provider.fetch(:refresh_access_token).call("refresh-token-1") if name == :paypal
      end

      assert_equal "https://#{name}.test/token", captured.fetch(0).fetch(:url)
      assert_equal "https://#{name}.test/token", captured.fetch(1).fetch(:url) if name == :paypal
    end
  end

  def test_factories_exist_for_selected_common_providers
    assert_equal "gitlab", BetterAuth::SocialProviders.gitlab(client_id: "id", client_secret: "secret").fetch(:id)
    assert_equal "discord", BetterAuth::SocialProviders.discord(client_id: "id", client_secret: "secret").fetch(:id)
    assert_equal "apple", BetterAuth::SocialProviders.apple(client_id: "id", client_secret: "secret").fetch(:id)
    assert_equal "microsoft-entra-id",
      BetterAuth::SocialProviders.microsoft_entra_id(client_id: "id", client_secret: "secret", tenant_id: "common").fetch(:id)
  end

  def test_factories_exist_for_all_upstream_social_providers
    expected = {
      apple: "apple",
      atlassian: "atlassian",
      cognito: "cognito",
      discord: "discord",
      dropbox: "dropbox",
      facebook: "facebook",
      figma: "figma",
      github: "github",
      gitlab: "gitlab",
      google: "google",
      huggingface: "huggingface",
      kakao: "kakao",
      kick: "kick",
      line: "line",
      linear: "linear",
      linkedin: "linkedin",
      microsoft: "microsoft",
      microsoft_entra_id: "microsoft-entra-id",
      naver: "naver",
      notion: "notion",
      paybin: "paybin",
      paypal: "paypal",
      polar: "polar",
      railway: "railway",
      reddit: "reddit",
      roblox: "roblox",
      salesforce: "salesforce",
      slack: "slack",
      spotify: "spotify",
      tiktok: "tiktok",
      twitch: "twitch",
      twitter: "twitter",
      vercel: "vercel",
      vk: "vk",
      wechat: "wechat",
      zoom: "zoom"
    }

    expected.each do |factory, id|
      options = {client_id: "id", client_secret: "secret"}
      options.merge!(domain: "cognito.example", region: "us-east-1", user_pool_id: "pool-1") if factory == :cognito
      provider = BetterAuth::SocialProviders.public_send(factory, **options)
      assert_equal id, provider.fetch(:id), "#{factory} should expose upstream provider id"
      assert provider.fetch(:create_authorization_url), "#{factory} should create authorization URLs"
      assert provider.fetch(:validate_authorization_code), "#{factory} should validate authorization codes"
      assert provider.fetch(:get_user_info), "#{factory} should fetch user info"
    end
  end

  def test_base_normalizes_oauth_token_expiration_fields
    now = Time.utc(2026, 4, 29, 12, 0, 0)
    tokens = BetterAuth::SocialProviders::Base.normalize_tokens(
      {
        "access_token" => "access-token",
        "refresh_token" => "refresh-token",
        "id_token" => "id-token",
        "expires_in" => 60,
        "refresh_token_expires_in" => 120,
        "scope" => "openid email",
        "token_type" => "Bearer"
      },
      now: now
    )

    assert_equal "access-token", tokens.fetch("accessToken")
    assert_equal "refresh-token", tokens.fetch("refreshToken")
    assert_equal "id-token", tokens.fetch("idToken")
    assert_equal now + 60, tokens.fetch("accessTokenExpiresAt")
    assert_equal now + 120, tokens.fetch("refreshTokenExpiresAt")
    assert_equal "openid,email", tokens.fetch("scope")
    assert_equal "Bearer", tokens.fetch("tokenType")
  end

  def test_generic_provider_applies_profile_mapping_override
    provider = BetterAuth::SocialProviders::Base.oauth_provider(
      id: "example",
      name: "Example",
      client_id: "id",
      client_secret: "secret",
      authorization_endpoint: "https://provider.example/authorize",
      token_endpoint: "https://provider.example/token",
      user_info_endpoint: "https://provider.example/userinfo",
      profile_map: ->(profile) {
        {
          id: profile.fetch("sub"),
          name: profile.fetch("name"),
          email: profile.fetch("email"),
          image: profile.fetch("picture"),
          emailVerified: profile.fetch("email_verified")
        }
      },
      get_user_info: ->(_tokens) {
        {
          "sub" => "profile-id",
          "name" => "Profile Name",
          "email" => "profile@example.com",
          "picture" => "https://example.com/avatar.png",
          "email_verified" => false
        }
      },
      map_profile_to_user: ->(_profile) { {name: "Mapped Name", emailVerified: true} }
    )

    info = provider.fetch(:get_user_info).call("accessToken" => "token")

    assert_equal "profile-id", info.fetch(:user).fetch(:id)
    assert_equal "Mapped Name", info.fetch(:user).fetch(:name)
    assert_equal true, info.fetch(:user).fetch(:emailVerified)
  end

  def test_existing_providers_append_configured_and_requested_scopes
    provider = BetterAuth::SocialProviders.discord(client_id: "discord-id", client_secret: "discord-secret", scope: ["guilds"])

    url = provider.fetch(:create_authorization_url).call(
      state: "state-1",
      redirect_uri: "http://localhost:3000/api/auth/callback/discord",
      scopes: ["bot"]
    )

    scope = Rack::Utils.parse_query(URI.parse(url).query).fetch("scope")
    assert_equal ["identify", "email", "guilds", "bot"], scope.split(" ")
  end

  def test_apple_applies_profile_mapping_override
    provider = BetterAuth::SocialProviders.apple(
      client_id: "apple-id",
      client_secret: "apple-secret",
      map_profile_to_user: ->(_profile) { {name: "Mapped Apple", emailVerified: false} }
    )

    info = provider.fetch(:get_user_info).call(
      idToken: fake_jwt("sub" => "apple-sub", "email" => "apple@example.com", "email_verified" => true, "name" => "Token Name")
    )

    assert_equal "Mapped Apple", info.fetch(:user).fetch(:name)
    assert_equal false, info.fetch(:user).fetch(:emailVerified)
  end

  def test_apple_does_not_use_email_as_name_fallback
    provider = BetterAuth::SocialProviders.apple(client_id: "apple-id", client_secret: "apple-secret")

    info = provider.fetch(:get_user_info).call(
      idToken: fake_jwt("sub" => "apple-sub", "email" => "relay@example.com", "email_verified" => true)
    )

    assert_equal "", info.fetch(:user).fetch(:name)
  end

  def test_vercel_provider_maps_preferred_username_scopes_pkce_and_overrides
    provider = BetterAuth::SocialProviders.vercel(
      client_id: "vercel-id",
      client_secret: "vercel-secret",
      scope: ["team:read"],
      get_user_info: ->(_tokens) {
        {
          "sub" => "vercel-sub",
          "preferred_username" => "vercel-user",
          "email" => "vercel@example.com",
          "email_verified" => true
        }
      },
      map_profile_to_user: ->(_profile) { {name: "Mapped Vercel"} }
    )

    url = provider.fetch(:create_authorization_url).call(
      state: "state-1",
      code_verifier: "verifier-1",
      redirect_uri: "http://localhost:3000/api/auth/callback/vercel",
      scopes: ["project:read"]
    )
    params = Rack::Utils.parse_query(URI.parse(url).query)

    assert_equal "Vercel", provider.fetch(:name)
    assert_equal "vercel-id", params.fetch("client_id")
    assert_equal ["team:read", "project:read"], params.fetch("scope").split(" ")
    assert_equal BetterAuth::SocialProviders::Base.pkce_challenge("verifier-1"), params.fetch("code_challenge")
    assert_equal "S256", params.fetch("code_challenge_method")

    info = provider.fetch(:get_user_info).call(accessToken: "vercel-access")
    assert_equal "Mapped Vercel", info.fetch(:user).fetch(:name)
  end

  def test_railway_provider_maps_email_unverified_by_default
    provider = BetterAuth::SocialProviders.railway(
      client_id: "railway-id",
      client_secret: "railway-secret",
      get_user_info: ->(_tokens) {
        {
          "sub" => "railway-sub",
          "name" => "Railway User",
          "email" => "railway@example.com"
        }
      }
    )

    info = provider.fetch(:get_user_info).call(accessToken: "railway-access")

    assert_equal "Railway", provider.fetch(:name)
    assert_equal false, info.fetch(:user).fetch(:emailVerified)
  end

  def test_railway_validate_authorization_code_uses_basic_auth_header
    captured_form = nil
    captured_headers = nil
    post_form = lambda do |_url, form, headers = {}|
      captured_form = form
      captured_headers = headers
      {"access_token" => "railway-access"}
    end

    provider = BetterAuth::SocialProviders.railway(client_id: "railway-id", client_secret: "railway-secret")
    BetterAuth::SocialProviders::Base.stub(:post_form_json, post_form) do
      provider.fetch(:validate_authorization_code).call(
        code: "code-1",
        code_verifier: "verifier-1",
        redirect_uri: "http://localhost:3000/api/auth/callback/railway"
      )
    end

    assert_equal "Basic #{Base64.strict_encode64("railway-id:railway-secret")}", captured_headers.fetch("Authorization")
    refute_includes captured_form.keys, :client_id
    refute_includes captured_form.keys, :client_secret
  end

  def test_railway_refresh_access_token_uses_basic_auth_header
    captured_form = nil
    captured_headers = nil
    post_form = lambda do |_url, form, headers = {}|
      captured_form = form
      captured_headers = headers
      {"access_token" => "railway-access"}
    end

    provider = BetterAuth::SocialProviders.railway(client_id: "railway-id", client_secret: "railway-secret")
    BetterAuth::SocialProviders::Base.stub(:post_form_json, post_form) do
      provider.fetch(:refresh_access_token).call("railway-refresh")
    end

    assert_equal "Basic #{Base64.strict_encode64("railway-id:railway-secret")}", captured_headers.fetch("Authorization")
    assert_equal "refresh_token", captured_form.fetch(:grant_type)
    refute_includes captured_form.keys, :client_id
    refute_includes captured_form.keys, :client_secret
  end

  def test_basic_token_auth_providers_use_basic_auth_for_code_and_refresh
    providers = {
      figma: BetterAuth::SocialProviders.figma(client_id: "figma-id", client_secret: "figma-secret"),
      notion: BetterAuth::SocialProviders.notion(client_id: "notion-id", client_secret: "notion-secret"),
      paypal: BetterAuth::SocialProviders.paypal(client_id: "paypal-id", client_secret: "paypal-secret"),
      reddit: BetterAuth::SocialProviders.reddit(client_id: "reddit-id", client_secret: "reddit-secret"),
      twitter: BetterAuth::SocialProviders.twitter(client_id: "twitter-id", client_secret: "twitter-secret")
    }

    providers.each do |name, provider|
      captured, post_form = capture_post_form
      BetterAuth::SocialProviders::Base.stub(:post_form_json, post_form) do
        provider.fetch(:validate_authorization_code).call(
          code: "code-1",
          code_verifier: "verifier-1",
          redirect_uri: "http://localhost:3000/api/auth/callback/#{name}"
        )
        provider.fetch(:refresh_access_token).call("refresh-token-1")
      end

      assert_equal 2, captured.length, "#{name} should post for code exchange and refresh"
      assert_basic_token_request captured.fetch(0), "#{name}-id", "#{name}-secret"
      assert_equal "authorization_code", captured.fetch(0).fetch(:form).fetch(:grant_type)
      assert_basic_token_request captured.fetch(1), "#{name}-id", "#{name}-secret"
      assert_equal "refresh_token", captured.fetch(1).fetch(:form).fetch(:grant_type)
    end
  end

  def test_wechat_validate_authorization_code_uses_appid_secret_and_get_endpoint
    captured_url = nil
    get_json = lambda do |url, _headers = {}|
      captured_url = url
      {
        "access_token" => "wechat-access",
        "refresh_token" => "wechat-refresh",
        "expires_in" => 7200,
        "openid" => "openid-1",
        "unionid" => "union-1",
        "scope" => "snsapi_login"
      }
    end
    post_form = lambda do |_url, _form, _headers = {}|
      flunk "WeChat token exchange should use GET with appid and secret"
    end

    provider = BetterAuth::SocialProviders.wechat(client_id: "wx-app", client_secret: "wx-secret")
    tokens = nil
    BetterAuth::SocialProviders::Base.stub(:post_form_json, post_form) do
      BetterAuth::SocialProviders::Base.stub(:get_json, get_json) do
        tokens = provider.fetch(:validate_authorization_code).call(code: "code-1")
      end
    end

    params = Rack::Utils.parse_query(URI.parse(captured_url).query)
    assert_equal "wx-app", params.fetch("appid")
    assert_equal "wx-secret", params.fetch("secret")
    assert_equal "code-1", params.fetch("code")
    assert_equal "authorization_code", params.fetch("grant_type")
    assert_equal "wechat-access", tokens.fetch("accessToken")
    assert_equal "openid-1", tokens.fetch("openid")
    assert_equal "union-1", tokens.fetch("unionid")
  end

  def test_wechat_authorization_url_uses_default_lang
    provider = BetterAuth::SocialProviders.wechat(client_id: "wx-app", client_secret: "wx-secret")

    url = provider.fetch(:create_authorization_url).call(
      state: "state-1",
      redirect_uri: "http://localhost:3000/api/auth/callback/wechat"
    )

    assert_equal "wechat_redirect", URI.parse(url).fragment
    params = Rack::Utils.parse_query(URI.parse(url).query)
    assert_equal "wx-app", params.fetch("appid")
    assert_equal "cn", params.fetch("lang")
  end

  def test_wechat_refresh_access_token_uses_appid_and_get_endpoint
    captured_url = nil
    get_json = lambda do |url, _headers = {}|
      captured_url = url
      {
        "access_token" => "wechat-access",
        "refresh_token" => "wechat-refresh",
        "expires_in" => 7200,
        "openid" => "openid-1",
        "scope" => "snsapi_login"
      }
    end

    provider = BetterAuth::SocialProviders.wechat(client_id: "wx-app", client_secret: "wx-secret")
    tokens = nil
    BetterAuth::SocialProviders::Base.stub(:get_json, get_json) do
      tokens = provider.fetch(:refresh_access_token).call("wechat-refresh")
    end

    params = Rack::Utils.parse_query(URI.parse(captured_url).query)
    assert_equal "wx-app", params.fetch("appid")
    assert_equal "refresh_token", params.fetch("grant_type")
    assert_equal "wechat-refresh", params.fetch("refresh_token")
    refute params.key?("secret")
    assert_equal "openid-1", tokens.fetch("openid")
  end

  def test_wechat_get_user_info_uses_openid_and_maps_unionid_fallback
    captured_url = nil
    get_json = lambda do |url, _headers = {}|
      captured_url = url
      {
        "openid" => "openid-1",
        "unionid" => "union-1",
        "nickname" => "WeChat User",
        "headimgurl" => "https://wechat.example/avatar.png"
      }
    end

    provider = BetterAuth::SocialProviders.wechat(client_id: "wx-app", client_secret: "wx-secret")
    info = nil
    BetterAuth::SocialProviders::Base.stub(:get_json, get_json) do
      info = provider.fetch(:get_user_info).call("accessToken" => "wechat-access", "openid" => "openid-1")
    end

    params = Rack::Utils.parse_query(URI.parse(captured_url).query)
    assert_equal "wechat-access", params.fetch("access_token")
    assert_equal "openid-1", params.fetch("openid")
    assert_equal "zh_CN", params.fetch("lang")
    assert_equal "union-1", info.fetch(:user).fetch(:id)
    assert_equal "WeChat User", info.fetch(:user).fetch(:name)
    assert_equal "union-1@wechat.invalid", info.fetch(:user).fetch(:email)
    assert_equal false, info.fetch(:user).fetch(:emailVerified)
  end

  def test_wechat_get_user_info_uses_openid_placeholder_without_unionid
    profile = {
      "openid" => "openid-only",
      "nickname" => "WeChat User",
      "headimgurl" => "https://wechat.example/avatar.png"
    }
    provider = BetterAuth::SocialProviders.wechat(client_id: "wx-app", client_secret: "wx-secret")

    BetterAuth::SocialProviders::Base.stub(:get_json, ->(_url, _headers = {}) { profile }) do
      info = provider.fetch(:get_user_info).call("accessToken" => "wechat-access", "openid" => "openid-only")

      assert_equal "openid-only@wechat.invalid", info.fetch(:user).fetch(:email)
      refute info.fetch(:user).fetch(:emailVerified)
    end
  end

  def test_wechat_profile_mapping_can_override_placeholder_email
    profile = {
      "openid" => "openid-1",
      "unionid" => "union-1",
      "nickname" => "WeChat User",
      "headimgurl" => "https://wechat.example/avatar.png"
    }
    provider = BetterAuth::SocialProviders.wechat(
      client_id: "wx-app",
      client_secret: "wx-secret",
      map_profile_to_user: ->(_profile) { {email: "real@example.com", emailVerified: true} }
    )

    BetterAuth::SocialProviders::Base.stub(:get_json, ->(_url, _headers = {}) { profile }) do
      info = provider.fetch(:get_user_info).call("accessToken" => "wechat-access", "openid" => "openid-1")

      assert_equal "real@example.com", info.fetch(:user).fetch(:email)
      assert info.fetch(:user).fetch(:emailVerified)
    end
  end

  def test_wechat_get_user_info_returns_nil_without_openid
    provider = BetterAuth::SocialProviders.wechat(client_id: "wx-app", client_secret: "wx-secret")

    assert_nil provider.fetch(:get_user_info).call("accessToken" => "wechat-access")
  end

  def test_discord_null_email_can_be_synthesized_with_profile_mapping
    get_json = lambda do |_url, _headers = {}|
      {
        "id" => "discord-id",
        "username" => "phoneonly",
        "global_name" => nil,
        "email" => nil,
        "verified" => false,
        "avatar" => nil,
        "discriminator" => "0"
      }
    end
    provider = BetterAuth::SocialProviders.discord(
      client_id: "discord-id",
      client_secret: "discord-secret",
      map_profile_to_user: ->(profile) { {email: "#{profile.fetch("id")}@discord.local", emailVerified: true} }
    )

    info = nil
    BetterAuth::SocialProviders::Base.stub(:get_json, get_json) do
      info = provider.fetch(:get_user_info).call(accessToken: "discord-access")
    end

    assert_equal "discord-id@discord.local", info.fetch(:user).fetch(:email)
    assert_equal true, info.fetch(:user).fetch(:emailVerified)
  end

  def test_discord_default_avatar_uses_snowflake_for_modern_accounts
    assert_equal "https://cdn.discordapp.com/embed/avatars/2.png",
      BetterAuth::SocialProviders.discord_avatar_url({"id" => "175928847299117063", "discriminator" => "0", "avatar" => nil})
  end

  def test_microsoft_refresh_access_token_includes_scope_param
    captured_form = nil
    post_form = lambda do |_url, form, _headers = {}|
      captured_form = form
      {"access_token" => "new-access"}
    end

    provider = BetterAuth::SocialProviders.microsoft(client_id: "microsoft-id", client_secret: "secret", scope: ["Calendars.Read"])
    BetterAuth::SocialProviders::Base.stub(:post_form_json, post_form) do
      provider.fetch(:refresh_access_token).call("refresh-token")
    end

    assert_equal "openid profile email User.Read offline_access Calendars.Read", captured_form.fetch(:scope)
  end

  def test_microsoft_get_user_info_fetches_profile_photo_data_uri
    captured_url = nil
    captured_headers = nil
    get_bytes = lambda do |url, headers = {}|
      captured_url = url
      captured_headers = headers
      "jpeg-bytes"
    end

    provider = BetterAuth::SocialProviders.microsoft(client_id: "microsoft-id", profile_photo_size: 64)
    info = nil
    BetterAuth::SocialProviders::Base.stub(:get_bytes, get_bytes) do
      info = provider.fetch(:get_user_info).call(
        idToken: fake_jwt("sub" => "ms-sub", "email" => "microsoft@example.com", "name" => "Microsoft User", "email_verified" => true),
        accessToken: "access-token"
      )
    end

    assert_equal "https://graph.microsoft.com/v1.0/me/photos/64x64/$value", captured_url
    assert_equal "Bearer access-token", captured_headers.fetch("Authorization")
    assert_equal "data:image/jpeg;base64, anBlZy1ieXRlcw==", info.fetch(:user).fetch(:image)
  end

  private

  def paypal_provider(**options)
    BetterAuth::SocialProviders.paypal(
      client_id: "paypal-id",
      client_secret: "paypal-secret",
      environment: "live",
      **options
    )
  end

  def paypal_id_token_claims(overrides = {})
    {
      "iss" => "https://www.paypal.com",
      "aud" => "paypal-id",
      "sub" => "paypal-sub",
      "nonce" => "nonce-1"
    }.merge(overrides)
  end

  def paypal_profile(overrides = {})
    {
      "user_id" => "paypal-account",
      "name" => "PayPal User",
      "email" => "paypal@example.com",
      "email_verified" => true,
      "picture" => "https://paypal.example/avatar.png"
    }.merge(overrides)
  end

  def reddit_profile(id, oauth_client_id: "reddit-app")
    {
      "id" => id,
      "name" => "reddit-#{id}",
      "icon_img" => "https://reddit.example/#{id}.png",
      "has_verified_email" => true,
      "oauth_client_id" => oauth_client_id
    }
  end

  def microsoft_provider_for_test(key, tenant_id:, authority: nil)
    options = {
      client_id: "microsoft-id",
      tenant_id: tenant_id,
      jwks: {"keys" => [rsa_public_jwk(key, "microsoft-tenant-kid")]}
    }
    options[:authority] = authority if authority
    BetterAuth::SocialProviders.microsoft(**options)
  end

  def microsoft_token(key, tid:, issuer: nil, authority: "https://login.microsoftonline.com")
    signed_jwt(
      key,
      "microsoft-tenant-kid",
      "iss" => issuer || "#{authority}/#{tid}/v2.0",
      "aud" => "microsoft-id",
      "sub" => "ms-sub",
      "tid" => tid
    )
  end

  def microsoft_consumer_tenant_id
    "9188040d-6c67-4c5b-b112-36a304b66dad"
  end

  def microsoft_work_tenant_id
    "11111111-2222-3333-4444-555555555555"
  end

  def facebook_profile(id)
    {
      "id" => id,
      "name" => "Facebook User",
      "email" => "#{id}@example.com",
      "picture" => {"data" => {"url" => "https://facebook.example/avatar.png"}}
    }
  end

  def auth_params(url)
    Rack::Utils.parse_query(URI.parse(url).query)
  end

  def capture_post_form(response = {"access_token" => "access-token"})
    captured = []
    stub = lambda do |url, form, headers = {}|
      captured << {url: url, form: form, headers: headers}
      response
    end

    [captured, stub]
  end

  def assert_basic_token_request(request, client_id, client_secret)
    assert_equal "Basic #{Base64.strict_encode64("#{client_id}:#{client_secret}")}", request.fetch(:headers).fetch("Authorization")
    refute_includes request.fetch(:form).keys, :client_id
    refute_includes request.fetch(:form).keys, :client_secret
  end

  def assert_body_credentials_request(request, client_id, client_secret)
    assert_equal client_id, request.fetch(:form).fetch(:client_id)
    assert_equal client_secret, request.fetch(:form).fetch(:client_secret)
    refute request.fetch(:headers).key?("Authorization")
  end

  def unsigned_jwt(payload)
    encoded_header = Base64.urlsafe_encode64(JSON.generate({"alg" => "none"}), padding: false)
    encoded_payload = Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
    "#{encoded_header}.#{encoded_payload}."
  end

  def assert_nil_user_info(provider, tokens)
    assert_nil provider.fetch(:get_user_info).call(tokens)
  end

  def signed_jwt(private_key, kid, payload)
    algorithm_jwt(private_key, "RS256", payload, kid: kid)
  end

  def algorithm_jwt(signing_key, algorithm, payload, kid: nil)
    claims = {
      "iat" => Time.now.to_i,
      "exp" => Time.now.to_i + 3600
    }.merge(payload)
    headers = kid ? {kid: kid} : {}
    JWT.encode(claims, signing_key, algorithm, headers)
  end

  def rsa_public_jwk(key, kid)
    {
      "kid" => kid,
      "alg" => "RS256",
      "kty" => "RSA",
      "use" => "sig",
      "n" => base64url_bn(key.n),
      "e" => base64url_bn(key.e)
    }
  end

  def base64url_bn(number)
    hex = number.to_s(16)
    hex = "0#{hex}" if hex.length.odd?
    Base64.urlsafe_encode64([hex].pack("H*"), padding: false)
  end

  def fake_jwt(payload)
    unsigned_jwt(payload)
  end
end
