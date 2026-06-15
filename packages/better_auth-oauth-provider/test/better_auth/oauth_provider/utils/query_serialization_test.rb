# frozen_string_literal: true

require_relative "../../../test_helper"

class OAuthProviderUtilsQuerySerializationTest < Minitest::Test
  include OAuthProviderFlowHelpers

  FakeContext = Struct.new(:secret)
  FakeCtx = Struct.new(:context)

  def test_client_parse_signed_query_stops_at_signature
    query = "?client_id=abc&resource=https%3A%2F%2Fapi.example&sig=one&after=ignored"

    parsed = BetterAuth::Plugins::OAuthProvider::Client.parse_signed_query(query)

    assert_equal "client_id=abc&resource=https%3A%2F%2Fapi.example&sig=one", parsed
  end

  def test_verify_oauth_query_params_matches_signed_query_helper
    ctx = FakeCtx.new(context: FakeContext.new(secret: SECRET))
    signed = BetterAuth::Plugins.oauth_signed_query(ctx, {"client_id" => "abc", "scope" => "openid profile"})

    assert BetterAuth::Plugins::OAuthProvider::Utils.verify_oauth_query_params(signed, SECRET)
  end
end
