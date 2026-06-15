# frozen_string_literal: true

require_relative "../../test_helper"

class OAuthProviderMetadataUtilitiesTest < Minitest::Test
  include OAuthProviderFlowHelpers

  FakeContext = Struct.new(:secret)
  FakeCtx = Struct.new(:context)

  def test_metadata_matches_upstream_core_fields_and_disable_jwt_plugin
    auth = build_auth(scopes: ["openid", "profile", "email", "offline_access"], disable_jwt_plugin: true)

    metadata = auth.api.get_open_id_config
    oauth_metadata = auth.api.get_o_auth_server_config

    assert_equal metadata[:issuer], oauth_metadata[:issuer]
    assert_equal "http://localhost:3000/api/auth/oauth2/authorize", metadata[:authorization_endpoint]
    assert_equal "http://localhost:3000/api/auth/oauth2/token", metadata[:token_endpoint]
    assert_equal "http://localhost:3000/api/auth/oauth2/register", metadata[:registration_endpoint]
    assert_equal "http://localhost:3000/api/auth/oauth2/introspect", metadata[:introspection_endpoint]
    assert_equal "http://localhost:3000/api/auth/oauth2/revoke", metadata[:revocation_endpoint]
    assert_equal "http://localhost:3000/api/auth/oauth2/userinfo", metadata[:userinfo_endpoint]
    assert_equal "http://localhost:3000/api/auth/oauth2/end-session", metadata[:end_session_endpoint]
    assert_equal ["code"], metadata[:response_types_supported]
    assert_equal ["query"], metadata[:response_modes_supported]
    assert_includes metadata[:grant_types_supported], "authorization_code"
    assert_includes metadata[:grant_types_supported], "client_credentials"
    assert_includes metadata[:grant_types_supported], "refresh_token"
    assert_equal ["client_secret_basic", "client_secret_post", "none"], metadata[:token_endpoint_auth_methods_supported]
    assert_equal ["client_secret_basic", "client_secret_post"], metadata[:introspection_endpoint_auth_methods_supported]
    assert_equal ["client_secret_basic", "client_secret_post"], metadata[:revocation_endpoint_auth_methods_supported]
    assert_equal ["S256"], metadata[:code_challenge_methods_supported]
    assert_equal true, metadata[:authorization_response_iss_parameter_supported]
    assert_equal ["public"], metadata[:subject_types_supported]
    assert_equal ["HS256"], metadata[:id_token_signing_alg_values_supported]
    assert_includes metadata[:prompt_values_supported], "none"
  end

  def test_advertised_metadata_overrides_scopes_and_claims_but_rejects_unknown_scopes
    advertised_claims = %w[sub iss aud exp iat scope http://example.com/roles]
    auth = build_auth(
      scopes: ["openid", "profile", "email"],
      advertised_metadata: {
        scopes_supported: ["email"],
        claims_supported: advertised_claims
      }
    )

    metadata = auth.api.get_open_id_config
    assert_equal ["email"], metadata[:scopes_supported]
    assert_equal advertised_claims, metadata[:claims_supported]
    assert_equal metadata[:scopes_supported], auth.api.get_o_auth_server_config[:scopes_supported]

    error = assert_raises(BetterAuth::APIError) do
      build_auth(scopes: ["openid"], advertised_metadata: {scopes_supported: ["create:test"]})
    end

    assert_equal 400, error.status_code
    assert_match(/advertised_metadata\.scopes_supported create:test not found in scopes/, error.message)
  end

  def test_signed_oauth_query_preserves_repeated_params_through_verification
    ctx = FakeCtx.new(context: FakeContext.new(secret: SECRET))
    query = {
      "client_id" => "abc",
      "prompt" => "login consent",
      "resource" => ["https://api.example.com", "https://other.example.com"],
      "scope" => "openid profile"
    }

    signed = BetterAuth::Plugins.oauth_signed_query(ctx, query)
    verified = BetterAuth::Plugins.oauth_verified_query!(ctx, signed)

    assert_equal "abc", verified["client_id"]
    assert_equal "login consent", verified["prompt"]
    assert_equal ["https://api.example.com", "https://other.example.com"], verified["resource"]
    assert_equal "openid profile", verified["scope"]
  end

  def test_prompt_deletion_removes_only_selected_prompt_and_preserves_arrays
    query = {
      "client_id" => "abc",
      "prompt" => "login consent",
      "resource" => ["https://api.example.com", "https://other.example.com"]
    }

    BetterAuth::Plugins.oauth_delete_prompt!(query, "login")

    assert_equal "consent", query["prompt"]
    assert_equal ["https://api.example.com", "https://other.example.com"], query["resource"]

    BetterAuth::Plugins.oauth_delete_prompt!(query, "consent")

    refute query.key?("prompt")
    assert_equal ["https://api.example.com", "https://other.example.com"], query["resource"]
  end

  def test_timestamp_helpers_parse_epoch_millis_text_and_ignore_updated_at
    protocol = BetterAuth::Plugins::OAuthProtocol

    assert_equal 1_774_295_570, protocol.timestamp_seconds("1774295570569.0")
    assert_nil protocol.timestamp_seconds("not-a-date")
    assert_nil protocol.timestamp_seconds(Float::NAN)
    assert_nil protocol.timestamp_seconds(9e15)
    assert_nil protocol.timestamp_seconds("9e15")
    assert_equal "1774295570569.0", protocol.session_auth_time({"createdAt" => "1774295570569.0"})
    assert_equal 1_774_295_569, protocol.session_auth_time({"session" => {"created_at" => 1_774_295_569}})
    assert_nil protocol.session_auth_time({"updatedAt" => 1_774_295_569})
    assert_nil protocol.session_auth_time({"session" => {"updated_at" => "1774295570569.0"}})
  end
end
