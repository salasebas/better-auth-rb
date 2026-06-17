# frozen_string_literal: true

require_relative "../../test_helper"

class OAuthProviderConsentTest < Minitest::Test
  include OAuthProviderFlowHelpers

  def test_consent_code_can_only_be_approved_by_original_user_session
    auth = build_auth(scopes: ["openid"])
    cookie_a = sign_up_cookie(auth, email: "owner-a@example.com")
    client = create_client(auth, cookie_a, scope: "openid")
    status, headers, = authorize_response(auth, cookie_a, client, scope: "openid", prompt: "consent")
    assert_equal 302, status
    consent_code = extract_redirect_params(headers).fetch("consent_code")

    cookie_b = sign_up_cookie(auth, email: "owner-b@example.com")
    error = assert_raises(BetterAuth::APIError) do
      auth.api.oauth2_consent(headers: {"cookie" => cookie_b}, body: {accept: true, consent_code: consent_code})
    end

    assert_equal 403, error.status_code
  end

  def test_approved_consent_uses_pending_reference_id
    references = ["pending-reference", "recomputed-reference"]
    auth = build_auth(
      scopes: ["openid"],
      post_login: {
        consent_reference_id: ->(_info) { references.shift || "recomputed-reference" }
      }
    )
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid")
    status, headers, = authorize_response(auth, cookie, client, scope: "openid", prompt: "consent")
    assert_equal 302, status
    consent_code = extract_redirect_params(headers).fetch("consent_code")

    auth.api.oauth2_consent(headers: {"cookie" => cookie}, body: {accept: true, consent_code: consent_code})

    stored = auth.context.adapter.find_one(model: "oauthConsent", where: [{field: "referenceId", value: "pending-reference"}])
    recomputed = auth.context.adapter.find_one(model: "oauthConsent", where: [{field: "referenceId", value: "recomputed-reference"}])
    assert stored
    refute recomputed
  end
end
