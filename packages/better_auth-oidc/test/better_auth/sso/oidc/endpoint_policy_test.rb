# frozen_string_literal: true

require_relative "../../../test_helper"

class BetterAuthSSOOIDCEndpointPolicyTest < Minitest::Test
  Policy = BetterAuth::SSO::OIDC::EndpointPolicy

  def test_accepts_public_https_without_a_trusted_origin
    destination = Policy.validate("https://login.example.com/token", name: "OIDC tokenEndpoint", trusted_origin: ->(_url) { false })

    assert_equal "login.example.com", destination.uri.hostname
    refute destination.trusted
  end

  def test_rejects_plain_http_without_an_exact_trusted_origin
    error = assert_raises(Policy::Error) do
      Policy.validate("http://login.example.com/token", name: "OIDC tokenEndpoint", trusted_origin: ->(_url) { false })
    end

    assert_equal :https_required, error.reason
  end

  def test_rejects_special_use_literal_and_metadata_hosts
    urls = [
      "https://127.0.0.1/token",
      "https://10.0.0.1/token",
      "https://169.254.169.254/latest/meta-data",
      "https://224.0.0.1/token",
      "https://[::1]/token",
      "https://[fe80::1]/token",
      "https://[::ffff:127.0.0.1]/token",
      "https://metadata.google.internal/computeMetadata/v1"
    ]

    urls.each do |url|
      error = assert_raises(Policy::Error, url) { Policy.validate(url, name: "OIDC endpoint") }
      assert_equal :non_public_host, error.reason, url
    end
  end

  def test_allows_private_http_only_for_the_exact_trusted_origin
    origins = ["http://10.0.0.8:8080"]
    trusted = ->(url) { Policy.exact_origin_trusted?(url, origins) }

    destination = Policy.validate("http://10.0.0.8:8080/token", name: "OIDC tokenEndpoint", trusted_origin: trusted)
    assert destination.trusted

    assert_raises(Policy::Error) do
      Policy.validate("http://10.0.0.8:8081/token", name: "OIDC tokenEndpoint", trusted_origin: trusted)
    end

    refute Policy.exact_origin_trusted?("http://10.0.0.8:8080/token", ["http://10.0.*"])
  end

  def test_rejects_mixed_public_and_private_dns_answers
    error = assert_raises(Policy::Error) do
      Policy.validate(
        "https://login.example.com/token",
        name: "OIDC tokenEndpoint",
        resolve: true,
        resolver: ->(_host) { ["93.184.216.34", "10.0.0.5"] }
      )
    end

    assert_equal :non_public_address, error.reason
  end

  def test_pins_the_validated_address_and_does_not_resolve_again
    calls = 0
    destination = Policy.validate(
      "https://login.example.com/token",
      name: "OIDC tokenEndpoint",
      resolve: true,
      resolver: lambda do |_host|
        calls += 1
        (calls == 1) ? ["93.184.216.34"] : ["127.0.0.1"]
      end
    )
    http = Policy.build_http(destination, open_timeout: 1, read_timeout: 1)

    assert_equal 1, calls
    assert_equal "login.example.com", http.address
    assert_equal "93.184.216.34", http.ipaddr
    assert http.use_ssl?
  end
end
