# frozen_string_literal: true

require_relative "../test_support"

class BetterAuthAPIKeyDeleteAllExpiredRouteTest < Minitest::Test
  include APIKeyTestSupport

  def test_delete_all_expired_route_returns_upstream_payload_shape
    auth = build_api_key_auth(default_key_length: 12)

    assert_equal({success: true, error: nil}, auth.api.delete_all_expired_api_keys)
  end

  def test_delete_all_expired_route_is_not_http_routable
    auth = build_api_key_auth(default_key_length: 12)

    status, body = rack_json_response(auth, "POST", "/api-key/delete-all-expired-api-keys", body: {})

    assert_equal 404, status
    assert_equal "Not Found", body.fetch("error")
  end

  def test_delete_all_expired_returns_serializable_error_payload
    auth = build_api_key_auth(default_key_length: 12)
    auth.context.adapter.define_singleton_method(:delete_many) do |**|
      raise StandardError, "simulated adapter failure"
    end

    result = auth.api.delete_all_expired_api_keys

    assert_equal false, result.fetch(:success)
    err = result.fetch(:error)
    assert err.is_a?(Hash)
    assert_equal "simulated adapter failure", err.fetch(:message)
    assert_equal "StandardError", err.fetch(:name)
  end
end
