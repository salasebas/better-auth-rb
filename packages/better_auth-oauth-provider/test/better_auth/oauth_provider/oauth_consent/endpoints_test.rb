# frozen_string_literal: true

require_relative "../../../test_helper"

class OAuthProviderOauthConsentEndpointsTest < Minitest::Test
  include OAuthProviderFlowHelpers

  def test_consent_management_lists_reads_updates_and_deletes_consents
    auth = build_auth(scopes: ["openid", "profile"])
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid profile", skip_consent: false)
    issue_authorization_code_tokens(auth, cookie, client, scope: "openid profile")

    list = auth.api.get_oauth_consents(headers: {"cookie" => cookie})
    consent_id = list.first.fetch(:id)
    read = auth.api.get_oauth_consent(headers: {"cookie" => cookie}, query: {id: consent_id})
    updated = auth.api.update_oauth_consent(headers: {"cookie" => cookie}, body: {id: consent_id, scopes: ["openid"]})
    deleted = auth.api.delete_oauth_consent(headers: {"cookie" => cookie}, body: {id: consent_id})

    assert_equal consent_id, read[:id]
    assert_equal ["openid"], updated[:scopes]
    assert_equal({deleted: true}, deleted)
  end
end
