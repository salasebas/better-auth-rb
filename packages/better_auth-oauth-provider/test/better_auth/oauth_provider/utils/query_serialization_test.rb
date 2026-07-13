# frozen_string_literal: true

require_relative "../../../test_helper"

class OAuthProviderUtilsQuerySerializationTest < Minitest::Test
  include OAuthProviderFlowHelpers

  FakeContext = Struct.new(:secret)
  FakeCtx = Struct.new(:context)

  def test_client_parse_signed_query_keeps_only_declared_signed_parameters
    query = "?client_id=abc&resource=https%3A%2F%2Fapi.example&exp=9999999999&ba_iat=1&ba_param=client_id&ba_param=resource&ba_param=exp&ba_param=ba_iat&ba_param=ba_param&sig=one&after=ignored"

    parsed = BetterAuth::Plugins::OAuthProvider::Client.parse_signed_query(query)

    refute_includes parsed, "after=ignored"
    assert_includes parsed, "client_id=abc"
    assert_includes parsed, "sig=one"
  end

  def test_verify_oauth_query_params_matches_signed_query_helper
    ctx = FakeCtx.new(context: FakeContext.new(secret: SECRET))
    signed = BetterAuth::Plugins.oauth_signed_query(ctx, {"client_id" => "abc", "scope" => "openid profile"})

    assert BetterAuth::Plugins::OAuthProvider::Utils.verify_oauth_query_params(signed, SECRET)
  end

  def test_signed_query_canonicalizes_reordered_repeated_resource_values
    ctx = FakeCtx.new(context: FakeContext.new(secret: SECRET))
    signed = BetterAuth::Plugins.oauth_signed_query(ctx, {"client_id" => "abc", "resource" => ["https://b.example", "https://a.example"]})
    pairs = URI.decode_www_form(signed).reverse
    reordered = URI.encode_www_form(pairs)

    assert BetterAuth::Plugins::OAuthProvider::Utils.verify_oauth_query_params(reordered, SECRET)
    verified = BetterAuth::Plugins.oauth_verified_query!(ctx, reordered)
    assert_equal ["https://b.example", "https://a.example"], verified.fetch("resource")
  end

  def test_signed_query_rejects_duplicate_signature_and_fragments
    ctx = FakeCtx.new(context: FakeContext.new(secret: SECRET))
    signed = BetterAuth::Plugins.oauth_signed_query(ctx, {"client_id" => "abc"})

    refute BetterAuth::Plugins::OAuthProvider::Utils.verify_oauth_query_params("#{signed}&sig=second", SECRET)
    refute BetterAuth::Plugins::OAuthProvider::Utils.verify_oauth_query_params("#{signed}#fragment", SECRET)
  end

  def test_signing_strips_client_supplied_reserved_parameters
    ctx = FakeCtx.new(context: FakeContext.new(secret: SECRET))
    signed = BetterAuth::Plugins.oauth_signed_query(
      ctx,
      {"client_id" => "abc", "sig" => "attacker", "ba_param" => "attacker", "ba_pl" => "attacker", "exp" => "1"}
    )
    pairs = URI.decode_www_form(signed)

    assert_equal 1, pairs.count { |key, _value| key == "sig" }
    refute pairs.any? { |key, value| key == "ba_pl" || value == "attacker" }
    assert BetterAuth::Plugins::OAuthProvider::Utils.verify_oauth_query_params(signed, SECRET)
  end
end
