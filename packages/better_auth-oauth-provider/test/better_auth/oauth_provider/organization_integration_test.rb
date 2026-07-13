# frozen_string_literal: true

require "uri"
require_relative "../../test_helper"

class OAuthProviderOrganizationIntegrationTest < Minitest::Test
  include OAuthProviderFlowHelpers

  def test_dynamic_registration_creates_organizational_oauth_client
    auth = build_organization_auth(
      client_reference: ->(info) { info[:session]["activeOrganizationId"] }
    )
    cookie = sign_up_cookie(auth, email: "org-owner@example.com")
    org_cookie, organization = create_active_organization(auth, cookie, name: "My Org", slug: "my-org")

    client = auth.api.register_oauth_client(
      headers: {"cookie" => org_cookie},
      body: {
        redirect_uris: ["https://resource.example/callback"],
        token_endpoint_auth_method: "client_secret_post",
        grant_types: ["authorization_code"],
        response_types: ["code"],
        scope: "openid"
      }
    )

    assert_nil client[:user_id]
    assert_equal organization.fetch("id"), client[:reference_id]
    assert_equal [client[:client_id]], auth.api.get_oauth_clients(headers: {"cookie" => org_cookie}).map { |entry| entry[:client_id] }
    assert_equal client[:client_id], auth.api.get_oauth_client(headers: {"cookie" => org_cookie}, query: {client_id: client[:client_id]})[:client_id]
  end

  def test_post_login_consent_reference_tracks_organization_selection
    auth = build_organization_auth(
      scopes: ["openid", "read:posts"],
      post_login: {
        page: "/select-organization",
        should_redirect: ->(info) { info[:session]["activeOrganizationId"].to_s.empty? },
        consent_reference_id: lambda { |info|
          organization_id = info[:session]["activeOrganizationId"]
          raise BetterAuth::APIError.new("BAD_REQUEST", message: "must set organization for these scopes") if organization_id.to_s.empty?

          organization_id
        }
      }
    )
    cookie = sign_up_cookie(auth, email: "org-consent-owner@example.com")
    user = auth.api.get_session(headers: {"cookie" => cookie}).fetch(:user)
    organization = auth.api.create_organization(body: {name: "Consent Org", slug: "consent-org", userId: user.fetch("id")})
    client = auth.api.admin_create_oauth_client(
      body: {
        redirect_uris: ["https://resource.example/callback"],
        token_endpoint_auth_method: "client_secret_post",
        grant_types: ["authorization_code"],
        response_types: ["code"],
        scope: "openid read:posts"
      }
    )

    status, headers, = authorize_response(auth, cookie, client, scope: "openid read:posts", verifier: pkce_verifier)
    assert_equal 302, status
    select_uri = URI.parse(headers.fetch("location"))
    assert_equal "/select-organization", select_uri.path

    active_cookie = set_active_organization_cookie(auth, cookie, organization.fetch("id"))
    continued = auth.api.oauth2_continue(
      headers: {"cookie" => active_cookie},
      body: {postLogin: true, oauth_query: select_uri.query}
    )
    consent_params = Rack::Utils.parse_query(URI.parse(continued.fetch(:url)).query)
    assert consent_params.fetch("consent_code")

    consent = auth.api.oauth2_consent(
      headers: {"cookie" => active_cookie},
      body: {accept: true, consent_code: consent_params.fetch("consent_code")}
    )
    consent_callback = Rack::Utils.parse_query(URI.parse(consent.fetch(:redirectURI)).query)
    assert consent_callback.fetch("code")

    stored = auth.context.adapter.find_one(
      model: "oauthConsent",
      where: [
        {field: "clientId", value: client[:client_id]},
        {field: "referenceId", value: organization.fetch("id")}
      ]
    )
    assert stored
    assert_equal ["openid", "read:posts"], stored.fetch("scopes")

    reuse_status, reuse_headers, = authorize_response(auth, active_cookie, client, scope: "openid read:posts", verifier: pkce_verifier)
    reuse_params = extract_redirect_params(reuse_headers)
    assert_equal 302, reuse_status
    assert reuse_params["code"]
    refute reuse_params["consent_code"]

    second_org = auth.api.create_organization(body: {name: "Second Org", slug: "second-org", userId: user.fetch("id")})
    second_cookie = set_active_organization_cookie(auth, active_cookie, second_org.fetch("id"))
    second_status, second_headers, = authorize_response(auth, second_cookie, client, scope: "openid read:posts", verifier: pkce_verifier)
    second_params = extract_redirect_params(second_headers)

    assert_equal 302, second_status
    assert second_params["consent_code"]
    refute second_params["code"]
  end

  def test_post_login_allows_selecting_organization_team_before_consent
    auth = build_organization_auth(
      scopes: ["openid", "read:posts"],
      organization: {teams: {enabled: true}},
      post_login: {
        page: "/select-organization",
        should_redirect: ->(info) { info[:session]["activeOrganizationId"].to_s.empty? },
        consent_reference_id: ->(info) { info[:session]["activeOrganizationId"] }
      }
    )
    cookie = sign_up_cookie(auth, email: "org-team-owner@example.com")
    user = auth.api.get_session(headers: {"cookie" => cookie}).fetch(:user)
    organization = auth.api.create_organization(body: {name: "Team Org", slug: "team-org", userId: user.fetch("id")})
    team = auth.api.create_team(headers: {"cookie" => cookie}, body: {organizationId: organization.fetch("id"), name: "Engineering"})
    client = auth.api.admin_create_oauth_client(
      body: {
        redirect_uris: ["https://resource.example/callback"],
        token_endpoint_auth_method: "client_secret_post",
        grant_types: ["authorization_code"],
        response_types: ["code"],
        scope: "openid read:posts"
      }
    )

    status, headers, = authorize_response(auth, cookie, client, scope: "openid read:posts", verifier: pkce_verifier)
    assert_equal 302, status
    select_uri = URI.parse(headers.fetch("location"))
    assert_equal "/select-organization", select_uri.path

    organization_cookie = set_active_organization_cookie(auth, cookie, organization.fetch("id"))
    team_cookie = set_active_team_cookie(auth, organization_cookie, team.fetch("id"))
    session = auth.api.get_session(headers: {"cookie" => team_cookie})
    assert_equal organization.fetch("id"), session.fetch(:session).fetch("activeOrganizationId")
    assert_equal team.fetch("id"), session.fetch(:session).fetch("activeTeamId")

    continued = auth.api.oauth2_continue(
      headers: {"cookie" => team_cookie},
      body: {postLogin: true, oauth_query: select_uri.query}
    )
    consent_params = Rack::Utils.parse_query(URI.parse(continued.fetch(:url)).query)
    consent = auth.api.oauth2_consent(
      headers: {"cookie" => team_cookie},
      body: {accept: true, consent_code: consent_params.fetch("consent_code")}
    )
    callback = Rack::Utils.parse_query(URI.parse(consent.fetch(:redirectURI)).query)

    assert callback.fetch("code")
    stored = auth.context.adapter.find_one(
      model: "oauthConsent",
      where: [
        {field: "clientId", value: client[:client_id]},
        {field: "referenceId", value: organization.fetch("id")}
      ]
    )
    assert stored
  end

  private

  def build_organization_auth(options = {})
    organization_options = options.delete(:organization) || {}
    BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: OAuthProviderFlowHelpers::SECRET,
      database: :memory,
      email_and_password: {enabled: true},
      plugins: [
        BetterAuth::Plugins.organization(organization_options),
        BetterAuth::Plugins.jwt(jwks: {key_pair_config: {alg: "EdDSA"}}),
        BetterAuth::Plugins.oauth_provider({
          scopes: ["openid"],
          allow_dynamic_client_registration: true
        }.merge(options))
      ]
    )
  end

  def create_active_organization(auth, cookie, name:, slug:)
    created = auth.api.create_organization(
      headers: {"cookie" => cookie},
      body: {name: name, slug: slug},
      return_headers: true
    )
    [merge_cookie(cookie, created.fetch(:headers).fetch("set-cookie")), created.fetch(:response)]
  end

  def set_active_organization_cookie(auth, cookie, organization_id)
    response = auth.api.set_active_organization(
      headers: {"cookie" => cookie},
      body: {organizationId: organization_id},
      return_headers: true
    )
    merge_cookie(cookie, response.fetch(:headers).fetch("set-cookie"))
  end

  def set_active_team_cookie(auth, cookie, team_id)
    response = auth.api.set_active_team(
      headers: {"cookie" => cookie},
      body: {teamId: team_id},
      return_headers: true
    )
    merge_cookie(cookie, response.fetch(:headers).fetch("set-cookie"))
  end

  def merge_cookie(cookie, set_cookie)
    [cookie, set_cookie.to_s.lines.map { |line| line.split(";").first }.join("; ")].join("; ")
  end
end
