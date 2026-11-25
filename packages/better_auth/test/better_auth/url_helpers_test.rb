# frozen_string_literal: true

require "test_helper"

class BetterAuthURLHelpersTest < Minitest::Test
  HeaderSource = Struct.new(:url, :headers)

  def test_validate_proxy_header_rejects_malicious_forwarded_values
    refute BetterAuth::URLHelpers.valid_proxy_header?("javascript:alert(1)", :proto)
    refute BetterAuth::URLHelpers.valid_proxy_header?("file", :proto)
    refute BetterAuth::URLHelpers.valid_proxy_header?("../evil.com", :host)
    refute BetterAuth::URLHelpers.valid_proxy_header?("evil.com\0.example", :host)
    refute BetterAuth::URLHelpers.valid_proxy_header?("<script>", :host)
    refute BetterAuth::URLHelpers.valid_proxy_header?("", :host)
    refute BetterAuth::URLHelpers.valid_proxy_header?("   ", :host)
  end

  def test_port_range_is_checked_when_parsing_the_url
    assert BetterAuth::URLHelpers.valid_proxy_header?("example.com:99999", :host)

    error = assert_raises(BetterAuth::Error) do
      BetterAuth::URLHelpers.with_path("https://example.com:99999")
    end
    assert_includes error.message, "Please provide a valid base URL."
  end

  def test_validate_proxy_header_accepts_valid_hosts_and_protocols
    assert BetterAuth::URLHelpers.valid_proxy_header?("http", :proto)
    assert BetterAuth::URLHelpers.valid_proxy_header?("https", :proto)
    assert BetterAuth::URLHelpers.valid_proxy_header?("example.com:3000", :host)
    assert BetterAuth::URLHelpers.valid_proxy_header?("192.0.2.1", :host)
    assert BetterAuth::URLHelpers.valid_proxy_header?("192.0.2.1:8080", :host)
    assert BetterAuth::URLHelpers.valid_proxy_header?("[::1]", :host)
    assert BetterAuth::URLHelpers.valid_proxy_header?("localhost:3000", :host)
  end

  def test_host_pattern_matching_supports_exact_case_insensitive_and_wildcards
    assert BetterAuth::URLHelpers.matches_host_pattern?("Example.COM:3000", "example.com:3000")
    assert BetterAuth::URLHelpers.matches_host_pattern?("preview-123.vercel.app", "*.vercel.app")
    assert BetterAuth::URLHelpers.matches_host_pattern?("prefix-abc.example.com", "prefix-*.example.com")
    assert BetterAuth::URLHelpers.matches_host_pattern?("abx.example.com", "ab?.example.com")
    assert BetterAuth::URLHelpers.matches_host_pattern?("https://example.com/path", "example.com")
    refute BetterAuth::URLHelpers.matches_host_pattern?("evil.com", "example.com")
    refute BetterAuth::URLHelpers.matches_host_pattern?("", "example.com")
    refute BetterAuth::URLHelpers.matches_host_pattern?("example.com", "")
  end

  def test_get_host_from_source_honors_trusted_forwarded_host_then_fallbacks
    source = HeaderSource.new("https://fallback.example/path", {"x-forwarded-host" => "proxy.example", "host" => "host.example"})

    assert_equal "proxy.example", BetterAuth::URLHelpers.host_from_source(source, trusted_proxy_headers: true)
    assert_equal "host.example", BetterAuth::URLHelpers.host_from_source(source, trusted_proxy_headers: false)
    assert_equal "fallback.example", BetterAuth::URLHelpers.host_from_source(HeaderSource.new("https://fallback.example/path", {}))
    assert_equal "host.example", BetterAuth::URLHelpers.host_from_source(HeaderSource.new("https://fallback.example/path", {"x-forwarded-host" => "../evil", "host" => "host.example"}), trusted_proxy_headers: true)
  end

  def test_get_protocol_from_source_honors_config_forwarded_url_and_loopback_defaults
    assert_equal "http", BetterAuth::URLHelpers.protocol_from_source(HeaderSource.new("https://example.com", {}), config_protocol: "http")
    assert_equal "https", BetterAuth::URLHelpers.protocol_from_source(HeaderSource.new("http://example.com", {}), config_protocol: "https")
    assert_equal "http", BetterAuth::URLHelpers.protocol_from_source(HeaderSource.new("https://example.com", {"x-forwarded-proto" => "http"}), trusted_proxy_headers: true)
    assert_equal "https", BetterAuth::URLHelpers.protocol_from_source(HeaderSource.new("https://example.com", {"x-forwarded-proto" => "file"}), trusted_proxy_headers: true)
    assert_equal "http", BetterAuth::URLHelpers.protocol_from_source(HeaderSource.new("http://example.com", {}))
    assert_equal "http", BetterAuth::URLHelpers.protocol_from_source(HeaderSource.new(nil, {"host" => "localhost:3000"}))
    assert_equal "https", BetterAuth::URLHelpers.protocol_from_source(HeaderSource.new(nil, {"host" => "example.com"}))
  end

  def test_resolve_base_url_handles_static_and_dynamic_configs
    assert_equal "https://example.com/api/auth", BetterAuth::URLHelpers.resolve_base_url("https://example.com", "/api/auth")
    assert_equal "https://example.com/custom", BetterAuth::URLHelpers.resolve_base_url("https://example.com/custom", "/api/auth")

    source = HeaderSource.new("http://fallback.local/path", {"x-forwarded-host" => "preview-123.vercel.app", "x-forwarded-proto" => "https"})
    config = {allowed_hosts: ["*.vercel.app"], protocol: "https", fallback: "https://fallback.example"}
    assert_equal "https://preview-123.vercel.app/api/auth", BetterAuth::URLHelpers.resolve_base_url(config, "/api/auth", source, trusted_proxy_headers: true)

    disallowed = HeaderSource.new("https://evil.example/path", {"host" => "evil.example"})
    assert_equal "https://fallback.example/api/auth", BetterAuth::URLHelpers.resolve_base_url(config, "/api/auth", disallowed)
  end
end
