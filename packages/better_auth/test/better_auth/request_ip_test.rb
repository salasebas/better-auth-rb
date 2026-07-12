# frozen_string_literal: true

require "rack/mock"
require_relative "../test_helper"

class BetterAuthRequestIPTest < Minitest::Test
  SECRET = "request-ip-secret-with-enough-entropy"

  def test_uses_framework_resolved_ip_by_default_instead_of_raw_forwarded_header
    config = BetterAuth::Configuration.new(secret: SECRET)
    request = Rack::Request.new(
      Rack::MockRequest.env_for(
        "/",
        "REMOTE_ADDR" => "203.0.113.7",
        "HTTP_X_FORWARDED_FOR" => "198.51.100.2"
      )
    )

    assert_equal "203.0.113.7", BetterAuth::RequestIP.client_ip(request, config)
  end

  def test_prefers_framework_remote_ip_when_available
    config = BetterAuth::Configuration.new(secret: SECRET)
    request = Struct.new(:remote_ip, :ip).new("198.51.100.10", "203.0.113.10")

    assert_equal "198.51.100.10", BetterAuth::RequestIP.client_ip(request, config)
  end

  def test_uses_configured_headers_in_order
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      advanced: {
        ip_address: {
          ip_address_headers: ["x-client-ip", "x-forwarded-for"]
        }
      }
    )
    request = Rack::Request.new(Rack::MockRequest.env_for("/", "HTTP_X_CLIENT_IP" => "203.0.113.7", "HTTP_X_FORWARDED_FOR" => "198.51.100.2"))

    assert_equal "203.0.113.7", BetterAuth::RequestIP.client_ip(request, config)
  end

  def test_rejects_untrusted_forwarded_chain_and_uses_direct_peer
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      advanced: {ip_address: {ip_address_headers: ["x-forwarded-for"]}}
    )
    request = Rack::Request.new(
      Rack::MockRequest.env_for(
        "/",
        "REMOTE_ADDR" => "192.0.2.10",
        "HTTP_X_FORWARDED_FOR" => "203.0.113.7, 10.0.0.5"
      )
    )

    assert_equal "192.0.2.10", BetterAuth::RequestIP.client_ip(request, config)
  end

  def test_resolves_forwarded_chain_from_right_to_left_with_trusted_proxies
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      advanced: {
        ip_address: {
          ip_address_headers: ["x-forwarded-for"],
          trusted_proxies: ["192.0.2.10", "10.0.0.0/8"]
        }
      }
    )
    request = Rack::Request.new(
      Rack::MockRequest.env_for(
        "/",
        "REMOTE_ADDR" => "192.0.2.10",
        "HTTP_X_FORWARDED_FOR" => "203.0.113.8, 198.51.100.20, 10.0.0.5"
      )
    )

    assert_equal "198.51.100.20", BetterAuth::RequestIP.client_ip(request, config)
  end

  def test_untrusted_direct_peer_cannot_forge_a_chain_ending_in_a_trusted_proxy
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      advanced: {
        ip_address: {
          ip_address_headers: ["x-forwarded-for"],
          trusted_proxies: ["192.0.2.10", "10.0.0.0/8"]
        }
      }
    )
    request = Rack::Request.new(
      Rack::MockRequest.env_for(
        "/",
        "REMOTE_ADDR" => "192.0.2.200",
        "HTTP_X_FORWARDED_FOR" => "203.0.113.8, 10.0.0.5"
      )
    )

    assert_equal "192.0.2.200", BetterAuth::RequestIP.client_ip(request, config)
  end

  def test_missing_direct_peer_does_not_allow_rack_to_resolve_raw_forwarded_header
    previous_rack_env = ENV["RACK_ENV"]
    ENV["RACK_ENV"] = "production"
    config = BetterAuth::Configuration.new(secret: SECRET)
    env = Rack::MockRequest.env_for("/", "HTTP_X_FORWARDED_FOR" => "198.51.100.20")
    env.delete("REMOTE_ADDR")

    assert_nil BetterAuth::RequestIP.client_ip(Rack::Request.new(env), config)
  ensure
    if previous_rack_env
      ENV["RACK_ENV"] = previous_rack_env
    else
      ENV.delete("RACK_ENV")
    end
  end

  def test_malformed_forwarded_chain_fails_closed_to_direct_peer
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      advanced: {
        ip_address: {
          ip_address_headers: ["x-forwarded-for"],
          trusted_proxies: ["192.0.2.10", "10.0.0.0/8"]
        }
      }
    )
    request = Rack::Request.new(
      Rack::MockRequest.env_for(
        "/",
        "REMOTE_ADDR" => "192.0.2.10",
        "HTTP_X_FORWARDED_FOR" => "198.51.100.20, not-an-ip, 10.0.0.5"
      )
    )

    assert_equal "192.0.2.10", BetterAuth::RequestIP.client_ip(request, config)
  end

  def test_all_trusted_forwarded_chain_fails_closed_to_direct_peer
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      advanced: {
        ip_address: {
          ip_address_headers: ["x-forwarded-for"],
          trusted_proxies: ["192.0.2.10", "10.0.0.0/8"]
        }
      }
    )
    request = Rack::Request.new(
      Rack::MockRequest.env_for(
        "/",
        "REMOTE_ADDR" => "192.0.2.10",
        "HTTP_X_FORWARDED_FOR" => "10.0.0.9, 10.0.0.5"
      )
    )

    assert_equal "192.0.2.10", BetterAuth::RequestIP.client_ip(request, config)
  end

  def test_mixed_valid_and_invalid_trusted_proxy_entries_fail_closed
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      advanced: {
        ip_address: {
          ip_address_headers: ["x-forwarded-for"],
          trusted_proxies: ["192.0.2.10", "10.0.0.0/8x"]
        }
      }
    )
    request = Rack::Request.new(
      Rack::MockRequest.env_for(
        "/",
        "REMOTE_ADDR" => "192.0.2.10",
        "HTTP_X_FORWARDED_FOR" => "198.51.100.20, 10.0.0.5"
      )
    )

    assert_equal "192.0.2.10", BetterAuth::RequestIP.client_ip(request, config)
  end

  def test_unwraps_endpoint_context_for_framework_ip_resolution
    config = BetterAuth::Configuration.new(secret: SECRET)
    request = Rack::Request.new(Rack::MockRequest.env_for("/", "REMOTE_ADDR" => "198.51.100.10"))
    context = Struct.new(:request, :headers).new(request, {"x-forwarded-for" => "203.0.113.7"})

    assert_equal "198.51.100.10", BetterAuth::RequestIP.client_ip(context, config)
  end

  def test_disable_ip_tracking_returns_nil
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      advanced: {ip_address: {disable_ip_tracking: true}}
    )
    request = Rack::Request.new(Rack::MockRequest.env_for("/", "HTTP_X_FORWARDED_FOR" => "203.0.113.7"))

    assert_nil BetterAuth::RequestIP.client_ip(request, config)
  end

  def test_masks_ipv6_addresses
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      advanced: {ip_address: {ip_address_headers: ["x-forwarded-for"], ipv6_subnet: 64}}
    )
    request = Rack::Request.new(Rack::MockRequest.env_for("/", "HTTP_X_FORWARDED_FOR" => "2001:db8:abcd:1234:ffff::1"))

    assert_equal "2001:db8:abcd:1234::", BetterAuth::RequestIP.client_ip(request, config)
  end

  def test_converts_ipv4_mapped_ipv6_to_ipv4
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      advanced: {ip_address: {ip_address_headers: ["x-forwarded-for"]}}
    )
    request = Rack::Request.new(Rack::MockRequest.env_for("/", "HTTP_X_FORWARDED_FOR" => "::ffff:192.0.2.1"))

    assert_equal "192.0.2.1", BetterAuth::RequestIP.client_ip(request, config)
  end

  def test_ipv6_subnet_does_not_affect_ipv4_addresses
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      advanced: {ip_address: {ip_address_headers: ["x-forwarded-for"], ipv6_subnet: 64}}
    )
    request = Rack::Request.new(Rack::MockRequest.env_for("/", "HTTP_X_FORWARDED_FOR" => "192.168.1.1"))

    assert_equal "192.168.1.1", BetterAuth::RequestIP.client_ip(request, config)
  end
end
