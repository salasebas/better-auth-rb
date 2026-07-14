# frozen_string_literal: true

require "json"
require_relative "../../test_helper"

class BetterAuthPluginsOneTapTest < Minitest::Test
  SECRET = "phase-eight-secret-with-enough-entropy-123"

  def test_callback_creates_google_oauth_user_and_session
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.one_tap(verify_id_token: google_verifier(
          email: "onetap@example.com",
          email_verified: true,
          name: "One Tap",
          picture: "https://example.com/avatar.png",
          sub: "google-sub-1"
        ))
      ]
    )

    status, headers, body = auth.api.one_tap_callback(
      body: {idToken: "valid-id-token"},
      as_response: true
    )
    data = JSON.parse(body.first)

    assert_equal 200, status
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token="
    assert_match(/\A[0-9a-f]{32}\z/, data.fetch("token"))
    assert_equal "onetap@example.com", data.dig("user", "email")
    assert_equal true, data.dig("user", "emailVerified")

    account = auth.context.internal_adapter.find_account_by_provider_id("google-sub-1", "google")
    refute_nil account
    assert_equal "valid-id-token", account["idToken"]
  end

  def test_callback_reuses_existing_google_account
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.one_tap(verify_id_token: google_verifier(
          email: "existing@example.com",
          email_verified: true,
          name: "Existing",
          sub: "google-sub-existing"
        ))
      ]
    )
    first = auth.api.one_tap_callback(body: {idToken: "first-token"})

    result = auth.api.one_tap_callback(body: {idToken: "second-token"})

    assert_equal first[:user]["id"], result[:user]["id"]
    assert_equal 1, auth.context.internal_adapter.find_accounts(first[:user]["id"]).length
  end

  def test_callback_signs_in_google_sub_owner_instead_of_unrelated_email_match
    shared_sub = "one-tap-sub-owned-by-user-a"
    email_match = "one-tap-email-collision-b@example.com"
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.one_tap(verify_id_token: google_verifier(
          email: email_match,
          email_verified: true,
          name: "Email Match B",
          sub: shared_sub
        ))
      ]
    )
    sub_owner = auth.context.internal_adapter.create_user(
      name: "Sub Owner A",
      email: "one-tap-sub-owner-a@example.com"
    )
    auth.context.internal_adapter.create_account(
      userId: sub_owner["id"],
      providerId: "google",
      accountId: shared_sub
    )
    email_matched_user = auth.context.internal_adapter.create_user(
      name: "Email Match B",
      email: email_match,
      emailVerified: false
    )

    result = auth.api.one_tap_callback(body: {idToken: "verified-token"})

    assert_equal sub_owner["id"], result[:user]["id"]
    refute_equal email_matched_user["id"], result[:user]["id"]
    refute auth.context.internal_adapter.find_user_by_id(email_matched_user["id"])["emailVerified"]
    assert_equal sub_owner["id"], auth.context.internal_adapter.find_account_by_provider_id(shared_sub, "google")["userId"]
  end

  def test_callback_rejects_existing_unverified_user_by_default_even_when_google_email_is_verified
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.one_tap(verify_id_token: google_verifier(
          email: "link@example.com",
          email_verified: true,
          name: "Linked",
          sub: "google-sub-link"
        ))
      ]
    )
    auth.api.sign_up_email(body: {email: "link@example.com", password: "password123", name: "Linked"})

    user = auth.context.internal_adapter.find_user_by_email("link@example.com")[:user]
    old_session_tokens = auth.context.internal_adapter.list_sessions(user["id"]).map { |session| session["token"] }

    error = assert_raises(BetterAuth::APIError) do
      auth.api.one_tap_callback(body: {idToken: "verified-token"})
    end

    assert_equal "Google sub doesn't match", error.message
    assert_nil auth.context.internal_adapter.find_account_by_provider_id("google-sub-link", "google")
    assert_equal old_session_tokens, auth.context.internal_adapter.list_sessions(user["id"]).map { |session| session["token"] }
  end

  def test_callback_rejects_trusted_google_for_existing_unverified_user_by_default
    auth = build_auth(
      account: {account_linking: {trusted_providers: ["google"]}},
      plugins: [
        BetterAuth::Plugins.one_tap(verify_id_token: google_verifier(
          email: "trusted-link@example.com",
          email_verified: false,
          name: "Trusted Link",
          sub: "google-sub-trusted-link"
        ))
      ]
    )
    auth.api.sign_up_email(body: {email: "trusted-link@example.com", password: "password123", name: "Trusted Link"})

    error = assert_raises(BetterAuth::APIError) do
      auth.api.one_tap_callback(body: {idToken: "trusted-token"})
    end

    assert_equal "Google sub doesn't match", error.message
    assert_nil auth.context.internal_adapter.find_account_by_provider_id("google-sub-trusted-link", "google")
  end

  def test_callback_links_existing_verified_local_user
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.one_tap(verify_id_token: google_verifier(
          email: "verified-local-one-tap@example.com",
          email_verified: true,
          name: "Verified Local",
          sub: "google-sub-verified-local"
        ))
      ]
    )
    auth.api.sign_up_email(body: {email: "verified-local-one-tap@example.com", password: "password123", name: "Verified"})
    user = auth.context.internal_adapter.find_user_by_email("verified-local-one-tap@example.com")[:user]
    auth.context.internal_adapter.update_user(user["id"], emailVerified: true)

    result = auth.api.one_tap_callback(body: {idToken: "verified-token"})

    assert_equal user["id"], result[:user]["id"]
    assert auth.context.internal_adapter.find_account_by_provider_id("google-sub-verified-local", "google")
  end

  def test_callback_require_local_email_verified_opt_out_supports_snake_and_camel_case
    [
      {account: {account_linking: {require_local_email_verified: false}}},
      {account: {accountLinking: {requireLocalEmailVerified: false}}}
    ].each_with_index do |linking_options, index|
      email = "one-tap-opt-out-#{index}@example.com"
      sub = "one-tap-opt-out-#{index}"
      auth = build_auth(
        linking_options.merge(
          plugins: [
            BetterAuth::Plugins.one_tap(verify_id_token: google_verifier(
              email: email,
              email_verified: true,
              name: "Opt Out",
              sub: sub
            ))
          ]
        )
      )
      auth.api.sign_up_email(body: {email: email, password: "password123", name: "Opt Out"})

      result = auth.api.one_tap_callback(body: {idToken: "verified-token"})

      assert_equal email, result[:user]["email"]
      assert_equal true, result[:user]["emailVerified"]
      assert auth.context.internal_adapter.find_account_by_provider_id(sub, "google")
      stored = auth.context.internal_adapter.find_user_by_email(email).fetch(:user)
      assert_equal true, stored.fetch("emailVerified")
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
      plugins: [
        BetterAuth::Plugins.one_tap(verify_id_token: google_verifier(
          email: "one-tap-promotion-veto@example.com",
          email_verified: true,
          name: "Veto",
          sub: "one-tap-promotion-veto"
        ))
      ]
    )
    auth.api.sign_up_email(body: {email: "one-tap-promotion-veto@example.com", password: "password123", name: "Veto"})
    user = auth.context.internal_adapter.find_user_by_email("one-tap-promotion-veto@example.com").fetch(:user)
    session_count = auth.context.internal_adapter.list_sessions(user.fetch("id")).length

    assert_raises(BetterAuth::Error) do
      auth.api.one_tap_callback(body: {idToken: "verified-token"})
    end

    assert_nil auth.context.internal_adapter.find_account_by_provider_id("one-tap-promotion-veto", "google")
    refute auth.context.internal_adapter.find_user_by_id(user.fetch("id")).fetch("emailVerified")
    assert_equal session_count, auth.context.internal_adapter.list_sessions(user.fetch("id")).length
  end

  def test_callback_respects_disable_implicit_linking_but_allows_new_user
    payload = {email: "blocked-one-tap@example.com", email_verified: true, name: "Blocked", sub: "blocked-one-tap"}
    auth = build_auth(
      account: {account_linking: {disable_implicit_linking: true}},
      plugins: [BetterAuth::Plugins.one_tap(verify_id_token: ->(_token, _ctx = nil, **_options) { payload.transform_keys(&:to_s) })]
    )
    auth.api.sign_up_email(body: {email: payload[:email], password: "password123", name: "Blocked"})

    error = assert_raises(BetterAuth::APIError) do
      auth.api.one_tap_callback(body: {idToken: "verified-token"})
    end
    assert_equal "Google sub doesn't match", error.message

    payload[:email] = "new-one-tap@example.com"
    payload[:sub] = "new-one-tap"
    result = auth.api.one_tap_callback(body: {idToken: "verified-token"})
    assert_equal "new-one-tap@example.com", result[:user]["email"]
  end

  def test_callback_rejects_blank_sub_without_persistence
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.one_tap(verify_id_token: google_verifier(
          email: "blank-one-tap@example.com",
          email_verified: true,
          name: "Blank",
          sub: "  "
        ))
      ]
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.one_tap_callback(body: {idToken: "verified-token"})
    end

    assert_equal "invalid id token", error.message
    assert_nil auth.context.internal_adapter.find_user_by_email("blank-one-tap@example.com")
    assert_empty auth.context.internal_adapter.adapter.find_many(model: "account")
    assert_empty auth.context.internal_adapter.adapter.find_many(model: "session")
  end

  def test_callback_rejects_linking_when_account_linking_is_disabled
    auth = build_auth(
      account: {account_linking: {enabled: false, trusted_providers: ["google"]}},
      plugins: [
        BetterAuth::Plugins.one_tap(verify_id_token: google_verifier(
          email: "disabled-link@example.com",
          email_verified: true,
          name: "Disabled Link",
          sub: "google-sub-disabled-link"
        ))
      ]
    )
    auth.api.sign_up_email(body: {email: "disabled-link@example.com", password: "password123", name: "Disabled Link"})

    error = assert_raises(BetterAuth::APIError) do
      auth.api.one_tap_callback(body: {idToken: "verified-token"})
    end

    assert_equal 401, error.status_code
    assert_equal "Google sub doesn't match", error.message
  end

  def test_callback_passes_configured_client_id_to_token_verifier
    audiences = []
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.one_tap(
          clientId: "one-tap-client-id",
          verify_id_token: ->(_token, _ctx = nil, audience: nil) {
            audiences << audience
            {
              "email" => "audience@example.com",
              "email_verified" => "true",
              "name" => "Audience",
              "sub" => "google-sub-audience"
            }
          }
        )
      ]
    )

    auth.api.one_tap_callback(body: {idToken: "audience-token"})

    assert_equal ["one-tap-client-id"], audiences
  end

  def test_callback_passes_google_provider_client_id_to_token_verifier
    audiences = []
    auth = build_auth(
      social_providers: {google: {client_id: "provider-client-id"}},
      plugins: [
        BetterAuth::Plugins.one_tap(
          verify_id_token: ->(_token, _ctx = nil, audience: nil) {
            audiences << audience
            {
              "email" => "provider-audience@example.com",
              "email_verified" => true,
              "name" => "Provider Audience",
              "sub" => "google-sub-provider-audience"
            }
          }
        )
      ]
    )

    auth.api.one_tap_callback(body: {idToken: "audience-token"})

    assert_equal ["provider-client-id"], audiences
  end

  def test_callback_fails_closed_before_verification_when_audience_is_missing
    verifier_calls = 0
    auth = build_auth(
      social_providers: {},
      plugins: [
        BetterAuth::Plugins.one_tap(
          verify_id_token: ->(_token, _ctx = nil, **_options) {
            verifier_calls += 1
            {
              "email" => "missing-audience@example.com",
              "email_verified" => true,
              "name" => "Missing Audience",
              "sub" => "google-sub-missing-audience"
            }
          }
        )
      ]
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.one_tap_callback(body: {idToken: "audience-token"})
    end

    assert_equal 400, error.status_code
    assert_includes error.message, "Google client ID is required"
    assert_equal 0, verifier_calls
  end

  def test_callback_fails_closed_before_verification_when_audience_is_empty
    verifier_calls = 0
    auth = build_auth(
      social_providers: {google: {client_id: ""}},
      plugins: [
        BetterAuth::Plugins.one_tap(
          verify_id_token: ->(_token, _ctx = nil, **_options) {
            verifier_calls += 1
            {
              "email" => "empty-audience@example.com",
              "email_verified" => true,
              "name" => "Empty Audience",
              "sub" => "google-sub-empty-audience"
            }
          }
        )
      ]
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.one_tap_callback(body: {idToken: "audience-token"})
    end

    assert_equal 400, error.status_code
    assert_includes error.message, "Google client ID is required"
    assert_equal 0, verifier_calls
  end

  def test_callback_accepts_exact_configured_hosted_domain
    auth = build_auth(
      social_providers: {google: {client_id: "google-client-id", hd: "company.com"}},
      plugins: [
        BetterAuth::Plugins.one_tap(verify_id_token: google_verifier(
          email: "one-tap-hd-match@company.com",
          email_verified: true,
          name: "Hosted Domain Match",
          sub: "one-tap-hd-match-sub",
          hd: "company.com"
        ))
      ]
    )

    result = auth.api.one_tap_callback(body: {idToken: "verified-token"})

    assert_equal "one-tap-hd-match@company.com", result[:user]["email"]
  end

  def test_callback_rejects_hosted_domain_that_does_not_exactly_match
    auth = build_auth(
      social_providers: {google: {client_id: "google-client-id", hd: "company.com"}},
      plugins: [
        BetterAuth::Plugins.one_tap(verify_id_token: google_verifier(
          email: "one-tap-hd-mismatch@other.com",
          email_verified: true,
          name: "Hosted Domain Mismatch",
          sub: "one-tap-hd-mismatch-sub",
          hd: "other.com"
        ))
      ]
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.one_tap_callback(body: {idToken: "verified-token"})
    end

    assert_equal 400, error.status_code
    assert_equal "invalid id token", error.message
    assert_nil auth.context.internal_adapter.find_user_by_email("one-tap-hd-mismatch@other.com")
  end

  def test_callback_accepts_nonempty_hosted_domain_for_wildcard
    auth = build_auth(
      social_providers: {google: {client_id: "google-client-id", hd: "*"}},
      plugins: [
        BetterAuth::Plugins.one_tap(verify_id_token: google_verifier(
          email: "one-tap-hd-wildcard@company.com",
          email_verified: true,
          name: "Hosted Domain Wildcard",
          sub: "one-tap-hd-wildcard-sub",
          hd: "company.com"
        ))
      ]
    )

    result = auth.api.one_tap_callback(body: {idToken: "verified-token"})

    assert_equal "one-tap-hd-wildcard@company.com", result[:user]["email"]
  end

  def test_callback_rejects_missing_hosted_domain_for_exact_restriction
    auth = build_auth(
      social_providers: {google: {client_id: "google-client-id", hd: "company.com"}},
      plugins: [
        BetterAuth::Plugins.one_tap(verify_id_token: google_verifier(
          email: "one-tap-hd-missing@company.com",
          email_verified: true,
          name: "Hosted Domain Missing",
          sub: "one-tap-hd-missing-sub"
        ))
      ]
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.one_tap_callback(body: {idToken: "verified-token"})
    end

    assert_equal 400, error.status_code
    assert_equal "invalid id token", error.message
  end

  def test_callback_rejects_missing_hosted_domain_for_wildcard_restriction
    auth = build_auth(
      social_providers: {google: {client_id: "google-client-id", hd: "*"}},
      plugins: [
        BetterAuth::Plugins.one_tap(verify_id_token: google_verifier(
          email: "one-tap-hd-wildcard-missing@example.com",
          email_verified: true,
          name: "Hosted Domain Wildcard Missing",
          sub: "one-tap-hd-wildcard-missing-sub"
        ))
      ]
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.one_tap_callback(body: {idToken: "verified-token"})
    end

    assert_equal 400, error.status_code
    assert_equal "invalid id token", error.message
  end

  def test_callback_enforces_hosted_domain_from_google_factory_options
    payload = {
      "email" => "factory-hd-match@company.com",
      "email_verified" => true,
      "name" => "Factory Hosted Domain",
      "sub" => "factory-hd-match-sub",
      "hd" => "company.com"
    }
    google = BetterAuth::SocialProviders.google(
      client_id: "google-client-id",
      client_secret: "google-client-secret",
      hd: "company.com"
    )
    auth = build_auth(
      social_providers: {google: google},
      plugins: [
        BetterAuth::Plugins.one_tap(
          verify_id_token: ->(_token, _ctx = nil, **_options) { payload.dup }
        )
      ]
    )

    result = auth.api.one_tap_callback(body: {idToken: "matching-token"})
    assert_equal "factory-hd-match@company.com", result[:user]["email"]

    payload.replace(
      "email" => "factory-hd-mismatch@other.com",
      "email_verified" => true,
      "name" => "Factory Hosted Domain Mismatch",
      "sub" => "factory-hd-mismatch-sub",
      "hd" => "other.com"
    )
    mismatch = assert_raises(BetterAuth::APIError) do
      auth.api.one_tap_callback(body: {idToken: "mismatching-token"})
    end
    assert_equal "invalid id token", mismatch.message

    payload.delete("hd")
    payload["email"] = "factory-hd-missing@company.com"
    payload["sub"] = "factory-hd-missing-sub"
    missing = assert_raises(BetterAuth::APIError) do
      auth.api.one_tap_callback(body: {idToken: "missing-hd-token"})
    end
    assert_equal "invalid id token", missing.message
  end

  def test_callback_rejects_untrusted_google_sub_for_existing_user
    auth = build_auth(
      account: {account_linking: {trusted_providers: []}},
      plugins: [
        BetterAuth::Plugins.one_tap(verify_id_token: google_verifier(
          email: "untrusted@example.com",
          email_verified: false,
          name: "Untrusted",
          sub: "google-sub-untrusted"
        ))
      ]
    )
    auth.api.sign_up_email(body: {email: "untrusted@example.com", password: "password123", name: "Untrusted"})

    error = assert_raises(BetterAuth::APIError) do
      auth.api.one_tap_callback(body: {idToken: "unverified-token"})
    end

    assert_equal 401, error.status_code
    assert_equal "Google sub doesn't match", error.message
  end

  def test_callback_respects_disable_signup
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.one_tap(
          disable_signup: true,
          verify_id_token: google_verifier(
            email: "disabled@example.com",
            email_verified: true,
            name: "Disabled",
            sub: "google-sub-disabled"
          )
        )
      ]
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.one_tap_callback(body: {idToken: "valid-id-token"})
    end

    assert_equal 502, error.status_code
    assert_equal "User not found", error.message
  end

  def test_callback_rejects_invalid_token_and_returns_email_error_payload
    invalid = build_auth(plugins: [BetterAuth::Plugins.one_tap])

    error = assert_raises(BetterAuth::APIError) do
      invalid.api.one_tap_callback(body: {idToken: "not-a-jwt"})
    end

    assert_equal 400, error.status_code
    assert_equal "invalid id token", error.message

    no_email = build_auth(
      plugins: [
        BetterAuth::Plugins.one_tap(verify_id_token: ->(_token, _ctx = nil, **_options) { {"sub" => "no-email-sub"} })
      ]
    )

    assert_equal({error: "Email not available in token"}, no_email.api.one_tap_callback(body: {idToken: "valid-id-token"}))
  end

  def test_google_jwks_fetch_is_cached
    BetterAuth::Plugins.instance_variable_set(:@one_tap_google_jwks_cache, nil)
    calls = 0

    BetterAuth::HTTPClient.stub(:get_json, ->(_url) {
      calls += 1
      {"keys" => []}
    }) do
      BetterAuth::Plugins.one_tap_google_jwks
      BetterAuth::Plugins.one_tap_google_jwks
    end

    assert_equal 1, calls
  ensure
    BetterAuth::Plugins.instance_variable_set(:@one_tap_google_jwks_cache, nil)
  end

  private

  def build_auth(options = {})
    BetterAuth.auth({
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: :memory,
      email_and_password: {enabled: true},
      social_providers: {google: {client_id: "google-client-id"}}
    }.merge(options))
  end

  def google_verifier(payload)
    normalized = payload.transform_keys(&:to_s)
    ->(_token, _ctx = nil, **_options) { normalized }
  end
end
