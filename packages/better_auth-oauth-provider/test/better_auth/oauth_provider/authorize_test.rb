# frozen_string_literal: true

require_relative "../../test_helper"

class OAuthProviderAuthorizeTest < Minitest::Test
  include OAuthProviderFlowHelpers

  def test_authorize_rejects_unsupported_response_type_on_redirect_uri
    auth = build_auth(scopes: ["openid"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid")

    status, headers, = auth.api.oauth2_authorize(
      headers: {"cookie" => cookie},
      query: {
        response_type: "token",
        client_id: client[:client_id],
        redirect_uri: "https://resource.example/callback",
        scope: "openid"
      },
      as_response: true
    )

    params = extract_redirect_params(headers)

    assert_equal 302, status
    assert_equal "unsupported_response_type", params["error"]
    assert_equal "http://localhost:3000", params["iss"]
  end
end
