# frozen_string_literal: true

require "ipaddr"

module BetterAuth
  module Host
    CLOUD_METADATA_HOSTS = [
      "metadata.google.internal",
      "metadata.goog",
      "metadata",
      "instance-data",
      "instance-data.ec2.internal"
    ].freeze

    module_function

    def classify_host(host)
      canonical_input = normalize_input(host)
      lowered = canonical_input.downcase
      return {kind: :reserved, literal: :fqdn, canonical: ""} if lowered.empty?

      address = parse_ip(lowered)
      unless address
        return {kind: :localhost, literal: :fqdn, canonical: lowered} if lowered == "localhost" || lowered.end_with?(".localhost")
        return {kind: :cloud_metadata, literal: :fqdn, canonical: lowered} if CLOUD_METADATA_HOSTS.include?(lowered)

        return {kind: :public, literal: :fqdn, canonical: lowered}
      end

      native = address.respond_to?(:native) ? address.native : address
      if native.ipv4?
        canonical = native.to_s
        return {kind: classify_ipv4(canonical), literal: :ipv4, canonical: canonical}
      end

      canonical = expanded_ipv6(native)
      {kind: classify_ipv6(canonical), literal: :ipv6, canonical: canonical}
    end

    def loopback_ip?(host)
      classify_host(host)[:kind] == :loopback
    end

    def loopback_host?(host)
      [:loopback, :localhost].include?(classify_host(host)[:kind])
    end

    def public_routable_host?(host)
      classify_host(host)[:kind] == :public
    end

    def normalize_input(host)
      value = host.to_s.strip
      value = strip_port(value)
      value = value[1...-1] if value.start_with?("[") && value.end_with?("]")
      value = value.split("%", 2).first || ""
      value.gsub(/\.+\z/, "")
    end

    def strip_port(host)
      if host.start_with?("[")
        closing = host.index("]")
        return host unless closing

        return host[0..closing] if host[(closing + 1)..]&.match?(/\A:\d+\z/)
        return host
      end

      first_colon = host.index(":")
      return host unless first_colon
      return host if host.index(":", first_colon + 1)

      host[0...first_colon]
    end

    def parse_ip(host)
      IPAddr.new(host)
    rescue ArgumentError
      nil
    end

    def classify_ipv4(ip)
      return :unspecified if ip == "0.0.0.0"
      return :broadcast if ip == "255.255.255.255"

      value = ipv4_to_i(ip)
      return :loopback if ipv4_range?(value, "127.0.0.0", 8)
      return :private if ipv4_range?(value, "10.0.0.0", 8)
      return :private if ipv4_range?(value, "172.16.0.0", 12)
      return :private if ipv4_range?(value, "192.168.0.0", 16)
      return :link_local if ipv4_range?(value, "169.254.0.0", 16)
      return :shared_address_space if ipv4_range?(value, "100.64.0.0", 10)
      return :documentation if ipv4_range?(value, "192.0.2.0", 24)
      return :documentation if ipv4_range?(value, "198.51.100.0", 24)
      return :documentation if ipv4_range?(value, "203.0.113.0", 24)
      return :benchmarking if ipv4_range?(value, "198.18.0.0", 15)
      return :multicast if ipv4_range?(value, "224.0.0.0", 4)
      return :reserved if ipv4_range?(value, "0.0.0.0", 8)
      return :reserved if ipv4_range?(value, "192.0.0.0", 24)
      return :reserved if ipv4_range?(value, "240.0.0.0", 4)

      :public
    end

    def ipv4_to_i(ip)
      ip.split(".").map(&:to_i).reduce(0) { |sum, part| (sum << 8) + part }
    end

    def ipv4_range?(value, prefix, length)
      mask = (length == 32) ? 0xffffffff : ((0xffffffff << (32 - length)) & 0xffffffff)
      (value & mask) == (ipv4_to_i(prefix) & mask)
    end

    def classify_ipv6(expanded)
      return :unspecified if expanded == "0000:0000:0000:0000:0000:0000:0000:0000"
      return :loopback if expanded == "0000:0000:0000:0000:0000:0000:0000:0001"

      first_byte = expanded[0, 2].to_i(16)
      second_byte = expanded[2, 2].to_i(16)

      return :multicast if first_byte == 0xff
      return :link_local if first_byte == 0xfe && (second_byte & 0xc0) == 0x80
      return :private if (first_byte & 0xfe) == 0xfc
      return :documentation if expanded.start_with?("2001:0db8:")
      return :benchmarking if expanded.start_with?("2001:0002:0000:")

      if expanded.start_with?("2002:")
        embedded = embedded_ipv4(expanded, 1)
        return (classify_ipv4(embedded) == :public) ? :public : :reserved if embedded
      end

      if expanded.start_with?("0064:ff9b:0000:0000:0000:0000:")
        embedded = embedded_ipv4(expanded, 6)
        return :reserved if embedded
      end

      return :reserved if expanded.start_with?("0064:ff9b:0001:")

      if expanded.start_with?("2001:0000:")
        embedded = embedded_ipv4(expanded, 6, xor: true)
        return :reserved if embedded
      end

      return :reserved if expanded.start_with?("0100:0000:0000:0000:")
      return :documentation if expanded.start_with?("3fff:0")
      return :reserved if expanded.start_with?("5f00:")

      :public
    end

    def embedded_ipv4(expanded, start_group, xor: false)
      groups = expanded.split(":")
      combined = (groups.fetch(start_group).to_i(16) << 16) | groups.fetch(start_group + 1).to_i(16)
      combined ^= 0xffffffff if xor
      [
        (combined >> 24) & 0xff,
        (combined >> 16) & 0xff,
        (combined >> 8) & 0xff,
        combined & 0xff
      ].join(".")
    rescue IndexError
      nil
    end

    def expanded_ipv6(address)
      address.hton.bytes.each_slice(2).map do |high, low|
        ((high << 8) + low).to_s(16).rjust(4, "0")
      end.join(":")
    end
  end
end
