# frozen_string_literal: true

require_relative "../../test_helper"

class OAuthProviderMcpTest < Minitest::Test
  include OAuthProviderFlowHelpers

  MCP = BetterAuth::Plugins::OAuthProvider::MCP

  def test_www_authenticate_points_to_protected_resource_metadata
    header = BetterAuth::Plugins::OAuthProvider::MCP.www_authenticate(
      ["http://localhost:5000", "http://localhost:5000/resource1"]
    )

    assert_equal(
      'Bearer resource_metadata="http://localhost:5000/.well-known/oauth-protected-resource", Bearer resource_metadata="http://localhost:5000/.well-known/oauth-protected-resource/resource1"',
      header
    )
  end

  def test_handle_mcp_errors_adds_www_authenticate_header
    error = BetterAuth::APIError.new("UNAUTHORIZED", message: "missing authorization header")

    wrapped = assert_raises(BetterAuth::APIError) do
      BetterAuth::Plugins::OAuthProvider::MCP.handle_mcp_errors(error, "urn:api", resource_metadata_mappings: {"urn:api" => "https://api.example/.well-known/oauth-protected-resource"})
    end

    assert_equal 401, wrapped.status_code
    assert_equal 'Bearer resource_metadata="https://api.example/.well-known/oauth-protected-resource"', wrapped.headers["www-authenticate"]
  end

  def test_mcp_handler_normalizes_verifier_decode_errors_to_challenge
    request = Struct.new(:headers).new({"authorization" => "Bearer bad-token"})
    handler = BetterAuth::Plugins::OAuthProvider::MCP.mcp_handler(
      resource: "urn:api",
      resource_metadata_mappings: {"urn:api" => "https://api.example/.well-known/oauth-protected-resource"},
      verifier: ->(_token) { raise JWT::DecodeError, "bad token" }
    ) { |_request, jwt| jwt }

    wrapped = assert_raises(BetterAuth::APIError) { handler.call(request) }

    assert_equal 401, wrapped.status_code
    assert_equal 'Bearer resource_metadata="https://api.example/.well-known/oauth-protected-resource"', wrapped.headers["www-authenticate"]
  end

  def test_mcp_handler_with_verifier_accepts_valid_jwt
    auth = build_auth(scopes: ["read"])
    cookie = sign_up_cookie(auth, email: "mcp-handler@example.com")
    client = create_client(auth, cookie, grant_types: ["client_credentials"], response_types: [], scope: "read")
    audience = "http://localhost:3000"
    tokens = auth.api.o_auth2_token(
      body: {
        grant_type: "client_credentials",
        client_id: client[:client_id],
        client_secret: client[:client_secret],
        scope: "read",
        resource: audience
      }
    )
    ctx = BetterAuth::Endpoint::Context.new(
      path: "/mcp",
      method: "GET",
      query: {},
      body: {},
      params: {},
      headers: {},
      context: auth.context
    )
    request = Struct.new(:headers).new({"authorization" => "Bearer #{tokens[:access_token]}"})
    handler = MCP.mcp_handler_with_verifier(
      verify_options: {audience: audience, issuer: "http://localhost:3000"},
      ctx: ctx
    ) { |_request, jwt| jwt.fetch("scope") || jwt.fetch(:scope) }

    assert_equal "read", handler.call(request)
  end

  def test_mcp_handler_with_verifier_returns_challenge_for_invalid_token
    auth = build_auth(scopes: ["read"])
    ctx = BetterAuth::Endpoint::Context.new(
      path: "/mcp",
      method: "GET",
      query: {},
      body: {},
      params: {},
      headers: {},
      context: auth.context
    )
    request = Struct.new(:headers).new({"authorization" => "Bearer invalid"})
    handler = MCP.mcp_handler_with_verifier(
      verify_options: {audience: "http://localhost:3000", issuer: "http://localhost:3000"},
      resource_metadata_mappings: {"http://localhost:3000" => "https://api.example/.well-known/oauth-protected-resource"},
      ctx: ctx
    ) { |_request, _jwt| "ok" }

    wrapped = assert_raises(BetterAuth::APIError) { handler.call(request) }

    assert_equal 401, wrapped.status_code
    assert_match(/resource_metadata=/, wrapped.headers["www-authenticate"])
  end
end
