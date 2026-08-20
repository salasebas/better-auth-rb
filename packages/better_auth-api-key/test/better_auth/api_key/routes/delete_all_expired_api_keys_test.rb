# frozen_string_literal: true

require_relative "../test_support"

class BetterAuthAPIKeyDeleteAllExpiredRouteTest < Minitest::Test
  include APIKeyTestSupport

  def test_delete_all_expired_route_returns_upstream_payload_shape
    auth = build_api_key_auth(default_key_length: 12)

    assert_equal({success: true, error: nil}, auth.api.delete_all_expired_api_keys)
  end

  def test_delete_all_expired_swallows_adapter_failure_and_returns_success
    errors = []
    auth = build_api_key_auth(default_key_length: 12)
    logger = Object.new
    logger.define_singleton_method(:error) { |*arguments| errors << arguments }
    auth.context.define_singleton_method(:logger) { logger }
    auth.context.adapter.define_singleton_method(:delete_many) do |**|
      raise StandardError, "simulated adapter failure"
    end

    result = auth.api.delete_all_expired_api_keys

    assert_equal({success: true, error: nil}, result)
    assert_equal 1, errors.length
    assert_equal "Failed to delete expired API keys:", errors.first.first
    assert_equal "simulated adapter failure", errors.first.last.message
  end
end
