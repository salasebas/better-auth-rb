# frozen_string_literal: true

require_relative "../../../test_helper"

class OAuthProviderTypesZodTest < Minitest::Test
  include OAuthProviderFlowHelpers

  Zod = BetterAuth::Plugins::OAuthProvider::Types::Zod

  def test_safe_url_allows_https_loopback_http_and_custom_schemes
    assert Zod.safe_url?("https://example.com/callback")
    assert Zod.safe_url?("http://localhost/callback")
    assert Zod.safe_url?("myapp://callback")
  end

  def test_safe_url_rejects_dangerous_schemes_and_non_loopback_http
    refute Zod.safe_url?("javascript:alert(1)")
    refute Zod.safe_url?("data:text/plain,hello")
    refute Zod.safe_url?("http://example.com/callback")
  end

  def test_registration_rejects_invalid_redirect_uri_via_public_api
    auth = build_auth(scopes: ["openid"], allow_unauthenticated_client_registration: true)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.register_o_auth_client(
        body: {
          redirect_uris: ["javascript:alert(1)"],
          grant_types: ["authorization_code"],
          response_types: ["code"],
          scope: "openid"
        }
      )
    end

    assert_equal 400, error.status_code
  end
end
