# frozen_string_literal: true

require "test_helper"

class BetterAuthHostTest < Minitest::Test
  def test_classify_host_strips_ports_brackets_zone_identifiers_and_trailing_dots
    assert_equal "0000:0000:0000:0000:0000:0000:0000:0001", BetterAuth::Host.classify_host("[::1]:8080")[:canonical]
    assert_equal "127.0.0.1", BetterAuth::Host.classify_host("127.0.0.1:3000")[:canonical]
    assert_equal "example.com", BetterAuth::Host.classify_host("Example.COM.")[:canonical]
    assert_equal "fe80:0000:0000:0000:0000:0000:0000:0001", BetterAuth::Host.classify_host("fe80::1%lo0")[:canonical]
  end

  def test_classify_host_matches_upstream_ipv4_special_ranges
    cases = {
      "127.0.0.1" => :loopback,
      "0.0.0.0" => :unspecified,
      "255.255.255.255" => :broadcast,
      "10.0.0.1" => :private,
      "172.16.0.1" => :private,
      "192.168.1.1" => :private,
      "172.15.255.255" => :public,
      "172.32.0.0" => :public,
      "169.254.169.254" => :link_local,
      "100.64.0.1" => :shared_address_space,
      "100.63.255.255" => :public,
      "100.128.0.0" => :public,
      "192.0.2.1" => :documentation,
      "198.51.100.1" => :documentation,
      "203.0.113.1" => :documentation,
      "198.18.0.1" => :benchmarking,
      "224.0.0.1" => :multicast,
      "192.0.0.1" => :reserved,
      "240.0.0.1" => :reserved,
      "8.8.8.8" => :public
    }

    cases.each do |host, kind|
      assert_equal kind, BetterAuth::Host.classify_host(host)[:kind], host
      assert_equal :ipv4, BetterAuth::Host.classify_host(host)[:literal], host
    end
  end

  def test_classify_host_matches_upstream_ipv6_special_ranges_and_tunnel_bypasses
    cases = {
      "::1" => :loopback,
      "::" => :unspecified,
      "fe80::1" => :link_local,
      "fec0::1" => :public,
      "fc00::1" => :private,
      "ff00::1" => :multicast,
      "2001:db8::1" => :documentation,
      "2606:4700:4700::1111" => :public,
      "2002:7f00:0001::1" => :reserved,
      "2002:0808:0808::1" => :public,
      "64:ff9b::7f00:1" => :reserved,
      "2001:0000:4136:e378:8000:63bf:3fff:fdd2" => :reserved,
      "::ffff:127.0.0.1" => :loopback,
      "::ffff:a9fe:a9fe" => :link_local
    }

    cases.each do |host, kind|
      assert_equal kind, BetterAuth::Host.classify_host(host)[:kind], host
    end
  end

  def test_classify_host_matches_upstream_ipv6_special_purpose_range_boundaries
    special_cases = {
      "2001:2::" => :benchmarking,
      "2001:2::1" => :benchmarking,
      "2001:2:0:ffff:ffff:ffff:ffff:ffff" => :benchmarking,
      "64:ff9b:1::" => :reserved,
      "64:ff9b:1::1" => :reserved,
      "64:ff9b:1:ffff:ffff:ffff:ffff:ffff" => :reserved,
      "3fff::" => :documentation,
      "3fff::1" => :documentation,
      "3fff:0fff:ffff:ffff:ffff:ffff:ffff:ffff" => :documentation,
      "5f00::" => :reserved,
      "5f00::1" => :reserved,
      "5f00:ffff:ffff:ffff:ffff:ffff:ffff:ffff" => :reserved
    }

    special_cases.each do |host, kind|
      assert_equal kind, BetterAuth::Host.classify_host(host)[:kind], host
      refute BetterAuth::Host.public_routable_host?(host), host
    end

    ["2001:20::1", "2001:2:1::", "64:ff9b:2::", "3fff:1000::", "5f01::"].each do |host|
      assert_equal :public, BetterAuth::Host.classify_host(host)[:kind], host
      assert BetterAuth::Host.public_routable_host?(host), host
    end
  end

  def test_classify_host_handles_localhost_cloud_metadata_and_public_fqdns
    assert_equal :reserved, BetterAuth::Host.classify_host("  ")[:kind]
    assert_equal :localhost, BetterAuth::Host.classify_host("localhost")[:kind]
    assert_equal :localhost, BetterAuth::Host.classify_host("tenant.localhost")[:kind]
    assert_equal :public, BetterAuth::Host.classify_host("notlocalhost.example")[:kind]
    assert_equal :cloud_metadata, BetterAuth::Host.classify_host("metadata.google.internal")[:kind]
    assert_equal :cloud_metadata, BetterAuth::Host.classify_host("metadata.google.internal.")[:kind]
    assert_equal :public, BetterAuth::Host.classify_host("example.com")[:kind]
  end

  def test_loopback_and_public_predicates_match_upstream_security_rules
    assert BetterAuth::Host.loopback_ip?("127.0.0.1")
    assert BetterAuth::Host.loopback_ip?("[::1]:8080")
    refute BetterAuth::Host.loopback_ip?("localhost")
    refute BetterAuth::Host.loopback_ip?("0.0.0.0")

    assert BetterAuth::Host.loopback_host?("tenant.localhost")
    assert BetterAuth::Host.loopback_host?("127.1.2.3")
    refute BetterAuth::Host.loopback_host?("0.0.0.0")

    assert BetterAuth::Host.public_routable_host?("example.com")
    assert BetterAuth::Host.public_routable_host?("8.8.8.8")
    refute BetterAuth::Host.public_routable_host?("127.0.0.1")
    refute BetterAuth::Host.public_routable_host?("10.0.0.1")
    refute BetterAuth::Host.public_routable_host?("169.254.169.254")
    refute BetterAuth::Host.public_routable_host?("metadata")
    refute BetterAuth::Host.public_routable_host?("::ffff:127.0.0.1")
    refute BetterAuth::Host.public_routable_host?("fe80::1%lo0")
  end
end
