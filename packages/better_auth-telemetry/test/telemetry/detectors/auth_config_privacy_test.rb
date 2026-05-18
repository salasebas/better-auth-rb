# frozen_string_literal: true

require_relative "../../test_helper"
require "json"
require "better_auth/telemetry/detectors/auth_config"

class AuthConfigPrivacyTest < Minitest::Test
  AuthConfig = BetterAuth::Telemetry::Detectors::AuthConfig

  def test_redacted_config_does_not_emit_high_risk_raw_values
    sentinel = "internal-secret-sentinel"
    callable = -> { sentinel }
    custom_object = Object.new
    def custom_object.inspect = "custom-object-sentinel"

    payload = AuthConfig.call(
      {
        user: {
          fields: {internal_column: sentinel},
          additional_fields: {private_flag: {type: sentinel}}
        },
        session: {
          fields: {tenant_id: sentinel},
          additional_fields: {internal_session: sentinel}
        },
        account: {
          fields: {oauth_internal: sentinel},
          account_linking: {trusted_providers: ["github", sentinel]}
        },
        advanced: {
          database: {generate_id: callable},
          cross_sub_domain_cookies: {additional_cookies: [{name: sentinel}]},
          ip_address: {ip_address_headers: ["x-internal-ip", sentinel]}
        },
        on_api_error: {error_url: "https://#{sentinel}.example/error"}
      },
      {adapter: "Acme::Internal::ShardAdapter"}
    )

    encoded = JSON.generate(payload)

    refute_includes encoded, sentinel
    refute_includes encoded, "custom-object-sentinel"
    assert_equal 1, payload[:user][:fields]
    assert_equal 1, payload[:user][:additionalFields]
    assert_equal 1, payload[:session][:fields]
    assert_equal 1, payload[:session][:additionalFields]
    assert_equal 1, payload[:account][:fields]
    assert_equal 2, payload[:account][:accountLinking][:trustedProviders]
    assert_equal true, payload[:advanced][:database][:generateId]
    assert_equal 1, payload[:advanced][:crossSubDomainCookies][:additionalCookies]
    assert_equal 2, payload[:advanced][:ipAddress][:ipAddressHeaders]
    assert_equal true, payload[:onAPIError][:errorURL]
    assert_equal "adapter", payload[:adapter]
  end
end
