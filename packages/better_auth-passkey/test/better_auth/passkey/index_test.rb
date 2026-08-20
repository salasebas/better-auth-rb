# frozen_string_literal: true

require_relative "support"

class BetterAuthPasskeyIndexTest < Minitest::Test
  include BetterAuthPasskeyTestSupport

  def test_plugin_assembly_matches_upstream_entrypoint_contract
    plugin = BetterAuth::Plugins.passkey

    assert_equal "passkey", plugin.id
    assert_equal BetterAuth::Passkey::ErrorCodes::PASSKEY_ERROR_CODES, plugin.error_codes
    assert_equal "better-auth-passkey", plugin.options.fetch(:advanced).fetch(:web_authn_challenge_cookie)

    assert_equal "/passkey/generate-register-options", plugin.endpoints.fetch(:generate_passkey_registration_options).path
    assert_equal ["GET"], plugin.endpoints.fetch(:generate_passkey_registration_options).methods
    assert_equal "/passkey/generate-authenticate-options", plugin.endpoints.fetch(:generate_passkey_authentication_options).path
    assert_equal ["GET"], plugin.endpoints.fetch(:generate_passkey_authentication_options).methods
    assert_equal "/passkey/verify-registration", plugin.endpoints.fetch(:verify_passkey_registration).path
    assert_equal "/passkey/verify-authentication", plugin.endpoints.fetch(:verify_passkey_authentication).path
    assert_equal "/passkey/list-user-passkeys", plugin.endpoints.fetch(:list_passkeys).path
    assert_equal "/passkey/delete-passkey", plugin.endpoints.fetch(:delete_passkey).path
    assert_equal "/passkey/update-passkey", plugin.endpoints.fetch(:update_passkey).path
  end

  def test_challenge_generation_open_api_matches_upstream_get_query_contract
    auth = build_auth(plugins: [BetterAuth::Plugins.passkey, BetterAuth::Plugins.open_api])
    paths = auth.api.generate_openapi_schema.fetch(:paths)

    registration_path = paths.fetch("/passkey/generate-register-options")
    authentication_path = paths.fetch("/passkey/generate-authenticate-options")
    registration = registration_path.fetch(:get)
    authentication = authentication_path.fetch(:get)

    refute_includes registration_path.keys, :post
    refute_includes authentication_path.keys, :post
    refute_includes registration.keys, :requestBody
    refute_includes authentication.keys, :requestBody
    assert_equal(
      %w[authenticatorAttachment context name],
      registration.fetch(:parameters).map { |parameter| parameter.fetch(:name) }.sort
    )
    assert registration.fetch(:parameters).all? { |parameter| parameter[:in] == "query" && parameter[:required] == false }
  end
end
