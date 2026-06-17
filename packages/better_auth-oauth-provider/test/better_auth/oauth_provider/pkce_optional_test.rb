# frozen_string_literal: true

require_relative "../../test_helper"

class OAuthProviderPkceOptionalTest < Minitest::Test
  include OAuthProviderFlowHelpers

  def test_confidential_client_can_opt_out_of_pkce_for_authorization_code
    auth = build_auth(scopes: ["openid"])
    cookie = sign_up_cookie(auth)
    client = auth.api.admin_create_oauth_client(
      body: {
        redirect_uris: ["https://resource.example/callback"],
        token_endpoint_auth_method: "client_secret_post",
        require_pkce: false,
        scope: "openid",
        skip_consent: true
      }
    )
    code = authorization_code_for(auth, cookie, client, scope: "openid", verifier: nil)

    tokens = auth.api.oauth2_token(
      body: {
        grant_type: "authorization_code",
        code: code,
        redirect_uri: "https://resource.example/callback",
        client_id: client[:client_id],
        client_secret: client[:client_secret]
      }
    )

    assert tokens[:access_token]
    assert tokens[:id_token]
  end
end
