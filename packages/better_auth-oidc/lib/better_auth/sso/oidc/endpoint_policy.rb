# frozen_string_literal: true

require "net/http"
require "resolv"
require "uri"

module BetterAuth
  module SSO
    module OIDC
      module EndpointPolicy
        class Error < StandardError
          attr_reader :reason, :url

          def initialize(reason, message, url:)
            @reason = reason
            @url = url
            super(message)
          end
        end

        Destination = Struct.new(:uri, :trusted, :ip_address)

        module_function

        def validate(url, name:, trusted_origin: nil, resolve: false, resolver: nil)
          uri = parse_http_url(url, name)
          trusted = trusted_origin&.call(uri.to_s) == true
          validate_public_destination!(uri, name) unless trusted

          ip_address = resolve ? resolve_destination!(uri, name, trusted, resolver) : nil
          Destination.new(uri: uri, trusted: trusted, ip_address: ip_address)
        end

        def exact_origin_trusted?(url, trusted_origins)
          candidate = parse_http_url(url, "OIDC endpoint")
          candidate_origin = origin_tuple(candidate)

          Array(trusted_origins).any? do |origin|
            trusted_uri = URI.parse(origin.to_s)
            trusted_uri.is_a?(URI::HTTP) && !trusted_uri.host.to_s.empty? && origin_tuple(trusted_uri) == candidate_origin
          rescue URI::InvalidURIError
            false
          end
        rescue Error
          false
        end

        def build_http(destination, open_timeout:, read_timeout:)
          uri = destination.uri
          http = Net::HTTP.new(uri.hostname, uri.port, nil)
          http.ipaddr = destination.ip_address if destination.ip_address
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = open_timeout
          http.read_timeout = read_timeout
          http
        end

        def parse_http_url(url, name)
          uri = URI.parse(url.to_s)
          unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty? && uri.userinfo.nil? && uri.fragment.nil?
            raise Error.new(:invalid_url, "#{name} must be a valid HTTP(S) URL without credentials or a fragment", url: url)
          end

          uri
        rescue URI::InvalidURIError
          raise Error.new(:invalid_url, "#{name} must be a valid HTTP(S) URL", url: url)
        end

        def validate_public_destination!(uri, name)
          unless uri.scheme == "https"
            raise Error.new(:https_required, "#{name} must use HTTPS unless its exact origin is explicitly trusted", url: uri.to_s)
          end

          return if BetterAuth::Host.public_routable_host?(uri.hostname)

          raise Error.new(:non_public_host, "#{name} must use a publicly routable host unless its exact origin is explicitly trusted", url: uri.to_s)
        end

        def resolve_destination!(uri, name, trusted, resolver)
          return nil if trusted

          host = BetterAuth::Host.normalize_input(uri.hostname)
          classification = BetterAuth::Host.classify_host(host)
          addresses = if classification[:literal] == :fqdn
            Array((resolver || method(:resolve_addresses)).call(host)).map(&:to_s).uniq
          else
            [classification[:canonical]]
          end

          if addresses.empty?
            raise Error.new(:unresolved_host, "#{name} host did not resolve", url: uri.to_s)
          end
          unless addresses.all? { |address| BetterAuth::Host.public_routable_host?(address) }
            raise Error.new(:non_public_address, "#{name} resolved to a non-public address", url: uri.to_s)
          end

          addresses.first
        rescue Resolv::ResolvError, SocketError
          raise Error.new(:unresolved_host, "#{name} host did not resolve", url: uri.to_s)
        end

        def resolve_addresses(host)
          Resolv.getaddresses(host)
        end

        def origin_tuple(uri)
          [uri.scheme.to_s.downcase, BetterAuth::Host.normalize_input(uri.hostname), uri.port]
        end
      end
    end
  end
end
