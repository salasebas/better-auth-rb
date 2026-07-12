# frozen_string_literal: true

require "ipaddr"

module BetterAuth
  module RequestIP
    LOCALHOST_IP = "127.0.0.1"

    module_function

    def client_ip(source, options)
      ip_options = options.advanced[:ip_address] || {}
      return nil if ip_options[:disable_ip_tracking]

      request = unwrap_request(source)
      configured_headers = ip_options[:ip_address_headers]
      if configured_headers
        Array(configured_headers).each do |header|
          value = header_value(source, header)
          next unless value.is_a?(String)

          ip = ip_from_header(
            value,
            trusted_proxies: ip_options[:trusted_proxies],
            peer_ip: peer_ip(request),
            ipv6_subnet: ip_options[:ipv6_subnet]
          )
          return ip if ip
        end
      end

      ip = fallback_ip(request, allow_forwarded_headers: configured_headers.nil?)
      return normalize_ip(ip, ipv6_subnet: ip_options[:ipv6_subnet]) if valid_ip?(ip)

      LOCALHOST_IP if test_or_development?
    end

    def ip_from_header(value, trusted_proxies: nil, peer_ip: nil, ipv6_subnet: nil)
      forwarded_ips = value.split(",").map(&:strip).reject(&:empty?)
      return nil if forwarded_ips.empty?

      proxy_entries = Array(trusted_proxies).map(&:to_s).reject(&:empty?)
      if proxy_entries.any?
        proxies = proxy_entries.map { |entry| parse_trusted_proxy(entry) }
        return nil if proxies.any?(&:nil?)

        peer_address = parse_ip(peer_ip)
        return nil unless peer_address && proxies.any? { |proxy| proxy.include?(native_address(peer_address)) }

        forwarded_ips.reverse_each do |ip|
          address = parse_ip(ip)
          return nil unless address
          next if proxies.any? { |proxy| proxy.include?(native_address(address)) }

          return normalize_ip(ip, ipv6_subnet: ipv6_subnet)
        end
        return nil
      end

      return nil unless forwarded_ips.one? && valid_ip?(forwarded_ips.first)

      normalize_ip(forwarded_ips.first, ipv6_subnet: ipv6_subnet)
    end

    def header_value(request, header)
      return request.get_header(rack_header_name(header)) if request.respond_to?(:get_header)
      return request.headers[header.to_s.downcase] if request.respond_to?(:headers)
      return request[header.to_s.downcase] || request[header.to_s] || request[header.to_sym] if request.is_a?(Hash)

      nil
    end

    def fallback_ip(request, allow_forwarded_headers:)
      return nil unless request

      remote_ip = request.remote_ip.to_s if request.respond_to?(:remote_ip)
      return remote_ip if valid_ip?(remote_ip)

      direct_peer_ip = peer_ip(request)
      return nil unless valid_ip?(direct_peer_ip)

      if allow_forwarded_headers && request.respond_to?(:ip)
        ip = request.ip.to_s
        return ip if valid_ip?(ip)
      end

      direct_peer_ip
    end

    def peer_ip(request)
      if request.respond_to?(:get_header)
        value = request.get_header("REMOTE_ADDR")
        return value.to_s unless value.nil?
      end
      if request.respond_to?(:env)
        value = request.env["REMOTE_ADDR"]
        return value.to_s unless value.nil?
      end
      if request.is_a?(Hash)
        value = request["REMOTE_ADDR"] || request[:REMOTE_ADDR] || request[:remote_addr]
        return value.to_s unless value.nil?
      end

      nil
    end

    def unwrap_request(source)
      current = source
      seen = {}
      while current&.respond_to?(:request)
        break if seen[current.object_id]

        seen[current.object_id] = true
        nested = current.request
        break unless nested && !nested.equal?(current)

        current = nested
      end
      current
    end

    def rack_header_name(header)
      "HTTP_#{header.to_s.upcase.tr("-", "_")}"
    end

    def valid_ip?(ip)
      return false if ip.to_s.empty? || ip.to_s.match?(/\s/)

      !parse_ip(ip).nil?
    end

    def parse_ip(ip)
      IPAddr.new(ip)
    rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
      nil
    end

    def parse_trusted_proxy(entry)
      value = entry.to_s
      return nil if value.empty? || value.match?(/\s/)

      if value.include?("/")
        address, prefix = value.split("/", -1)
        return nil unless value.count("/") == 1 && prefix.match?(/\A\d+\z/)

        parsed_address = parse_ip(address)
        return nil unless parsed_address

        max_prefix = parsed_address.ipv4? ? 32 : 128
        return nil if prefix.to_i > max_prefix
      end

      IPAddr.new(value)
    rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
      nil
    end

    def native_address(address)
      if address.respond_to?(:ipv4_mapped?) && address.ipv4_mapped?
        address.native
      else
        address
      end
    end

    def normalize_ip(ip, ipv6_subnet: nil)
      address = IPAddr.new(ip)
      return address.native.to_s if address.respond_to?(:ipv4_mapped?) && address.ipv4_mapped?
      return address.to_s if address.ipv4?

      address.mask((ipv6_subnet || 64).to_i).to_s
    end

    def test_or_development?
      ["test", "development"].include?(ENV["RACK_ENV"]) ||
        ["test", "development"].include?(ENV["RAILS_ENV"]) ||
        ["test", "development"].include?(ENV["APP_ENV"])
    end
  end
end
