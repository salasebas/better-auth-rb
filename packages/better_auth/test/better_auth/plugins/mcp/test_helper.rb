# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "rack/mock"
require_relative "../../../test_helper"
require_relative "../../../support/password_test_helpers"

module MCPTestHelpers
  SECRET = "phase-eleven-secret-with-enough-entropy-123"

  def build_mcp_auth(options = nil, extra_plugins: [], **keyword_options)
    options = (options || {}).merge(keyword_options)
    BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: :memory,
      email_and_password: BetterAuthTestPasswordHelpers.fast_email_and_password_config,
      plugins: [BetterAuth::Plugins.mcp({login_page: "/login"}.merge(options)), *extra_plugins]
    )
  end

  def sign_up_cookie(auth, email: "mcp@example.com")
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: email, password: "password123", name: "MCP User"},
      as_response: true
    )
    cookie_header(headers.fetch("set-cookie"))
  end

  def cookie_header(set_cookie)
    set_cookie.to_s.lines.map { |line| line.split(";").first }.join("; ")
  end

  def pkce_verifier
    "mcp-code-verifier-123456789012345678901234567890"
  end

  def pkce_challenge(verifier = pkce_verifier)
    Base64.urlsafe_encode64(OpenSSL::Digest.digest("SHA256", verifier), padding: false)
  end

  def register_public_mcp_client(auth, redirect_uri: "https://mcp.example/callback", scope: "openid profile email offline_access")
    auth.api.mcp_register(
      body: {
        redirect_uris: [redirect_uri],
        token_endpoint_auth_method: "none",
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"],
        client_name: "MCP Public Client",
        scope: scope
      }
    )
  end

  def authorize_mcp_code(auth, cookie, client, redirect_uri: "https://mcp.example/callback", scope: "openid email offline_access", state: "mcp-state", verifier: pkce_verifier, resource: nil, prompt: nil)
    query = {
      response_type: "code",
      client_id: client[:client_id],
      redirect_uri: redirect_uri,
      scope: scope,
      state: state,
      code_challenge: pkce_challenge(verifier),
      code_challenge_method: "S256"
    }
    query[:resource] = resource if resource
    query[:prompt] = prompt if prompt

    status, headers, _body = auth.api.mcp_o_auth_authorize(
      headers: {"cookie" => cookie},
      query: query,
      as_response: true
    )

    assert_equal 302, status
    Rack::Utils.parse_query(URI.parse(headers.fetch("location")).query).fetch("code")
  end

  def exchange_mcp_code(auth, client, code, redirect_uri: "https://mcp.example/callback", verifier: pkce_verifier, resource: nil)
    body = {
      grant_type: "authorization_code",
      code: code,
      redirect_uri: redirect_uri,
      client_id: client[:client_id],
      code_verifier: verifier
    }
    body[:resource] = resource if resource
    auth.api.mcp_o_auth_token(body: body)
  end
end
