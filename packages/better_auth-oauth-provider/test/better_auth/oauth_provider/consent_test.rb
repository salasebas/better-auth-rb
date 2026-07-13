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

  def test_consent_uses_current_authoritative_session_not_stored_snapshot
    auth = build_auth(scopes: ["openid"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid")
    status, headers, = authorize_response(auth, cookie, client, scope: "openid", prompt: "consent")
    assert_equal 302, status
    consent_code = extract_redirect_params(headers).fetch("consent_code")
    _status, sign_in_headers, = auth.api.sign_in_email(
      body: {email: "oauth-provider@example.com", password: "password123"},
      as_response: true
    )
    current_cookie = sign_in_headers.fetch("set-cookie").lines.map { |line| line.split(";").first }.join("; ")
    current_session = auth.api.get_session(headers: {"cookie" => current_cookie}).fetch(:session)

    approved = auth.api.oauth2_consent(headers: {"cookie" => current_cookie}, body: {accept: true, consent_code: consent_code})
    code = Rack::Utils.parse_query(URI.parse(approved.fetch(:redirectURI)).query).fetch("code")
    tokens = auth.api.oauth2_token(body: {
      grant_type: "authorization_code",
      code: code,
      redirect_uri: "https://resource.example/callback",
      client_id: client[:client_id],
      client_secret: client[:client_secret],
      code_verifier: pkce_verifier
    })

    assert tokens[:access_token]
    access_token = auth.context.adapter.find_many(model: "oauthAccessToken").max_by { |record| record.fetch("createdAt") }
    assert_equal current_session.fetch("id"), access_token.fetch("sessionId")
  end

  def test_consent_rejects_deleted_current_session
    auth = build_auth(scopes: ["openid"])
    cookie = sign_up_cookie(auth)
    session = auth.api.get_session(headers: {"cookie" => cookie}).fetch(:session)
    client = create_client(auth, cookie, scope: "openid")
    status, headers, = authorize_response(auth, cookie, client, scope: "openid", prompt: "consent")
    assert_equal 302, status
    consent_code = extract_redirect_params(headers).fetch("consent_code")
    auth.context.adapter.delete(model: "session", where: [{field: "id", value: session.fetch("id")}])

    error = assert_raises(BetterAuth::APIError) do
      auth.api.oauth2_consent(headers: {"cookie" => cookie}, body: {accept: true, consent_code: consent_code})
    end

    assert_equal 401, error.status_code
  end
end
