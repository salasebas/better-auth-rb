# frozen_string_literal: true

require "ipaddr"
require "rack/utils"
require "uri"

module BetterAuth
  module Plugins
    module_function

    def expo(options = {})
      config = normalize_hash(options)
      Plugin.new(
        id: "expo",
        init: ->(_ctx) { expo_development_environment? ? {options: {trusted_origins: ["exp://"]}} : nil },
        on_request: expo_on_request(config),
        hooks: {
          after: [
            {
              matcher: ->(ctx) { %w[/callback /oauth2/callback /magic-link/verify /verify-email].any? { |path| ctx.path.to_s.start_with?(path) } },
              handler: ->(ctx) { expo_inject_cookie_into_deep_link(ctx) }
            }
          ]
        },
        endpoints: {
          expo_authorization_proxy: expo_authorization_proxy_endpoint
        },
        options: config
      )
    end

    def expo_authorization_proxy_endpoint
      Endpoint.new(
        path: "/expo-authorization-proxy",
        method: "GET",
        metadata: {
          openapi: {
            operationId: "expoAuthorizationProxy",
            description: "Proxy an Expo authorization redirect",
            parameters: [
              {in: "query", name: "authorizationURL", required: true, schema: {type: "string", format: "uri"}},
              {in: "query", name: "oauthState", required: false, schema: {type: "string"}}
            ],
            responses: {
              "302" => {description: "Redirects to the authorization URL"}
            }
          }
        }
      ) do |ctx|
        authorization_url = ctx.query[:authorizationURL] || ctx.query["authorizationURL"] || ctx.query[:authorization_url] || ctx.query["authorization_url"]
        oauth_state = ctx.query[:oauthState] || ctx.query["oauthState"] || ctx.query[:oauth_state] || ctx.query["oauth_state"]
        raise APIError.new("BAD_REQUEST", message: "Unexpected error") if authorization_url.to_s.empty?

        raise APIError.new("BAD_REQUEST", message: "Invalid authorizationURL") if authorization_url.include?("#")

        begin
          authorization_uri = expo_authorization_uri(authorization_url)
        rescue URI::InvalidURIError
          raise APIError.new("BAD_REQUEST", message: "Invalid authorizationURL")
        end

        authorization_origin = expo_browser_origin(authorization_uri)
        base_origin = expo_browser_origin(URI.parse(ctx.context.base_url.to_s))
        if authorization_uri.scheme != "https" || authorization_origin.nil? || base_origin.nil? || authorization_origin == base_origin
          raise APIError.new("BAD_REQUEST", message: "Invalid authorizationURL")
        end

        if oauth_state
          cookie = ctx.context.create_auth_cookie("oauth_state", max_age: 600)
          ctx.set_cookie(cookie.name, oauth_state, cookie.attributes)
        else
          state = Rack::Utils.parse_query(authorization_uri.query)["state"]
          raise APIError.new("BAD_REQUEST", message: "Unexpected error") if state.to_s.empty?

          cookie = ctx.context.create_auth_cookie("state", max_age: 300)
          ctx.set_signed_cookie(cookie.name, state, ctx.context.secret, cookie.attributes)
        end
        [302, ctx.response_headers.merge("location" => authorization_url), [""]]
      end
    end

    def expo_on_request(config)
      lambda do |request, _context|
        next if config[:disable_origin_override] || request.get_header("HTTP_ORIGIN")

        expo_origin = request.get_header("HTTP_EXPO_ORIGIN")
        next unless expo_origin

        env = request.env.dup
        env["HTTP_ORIGIN"] = expo_origin
        {request: Rack::Request.new(env)}
      end
    end

    def expo_authorization_uri(authorization_url)
      before_query, query = authorization_url.split("?", 2)
      normalized = before_query.tr("\\", "/").sub(/\Ahttps:\/*/i, "https://")
      normalized = "#{normalized}?#{query}" if query
      URI.parse(normalized.gsub(/%(?![0-9a-f]{2})/i, "%25"))
    end

    def expo_browser_origin(uri)
      scheme = uri.scheme&.downcase
      hostname = uri.hostname
      return unless scheme && hostname

      host = expo_browser_host(hostname)
      return unless host

      port = uri.port
      return unless port.between?(0, 65_535)

      default_port = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
      origin = "#{scheme}://#{host}"
      default_port ? origin : "#{origin}:#{port}"
    rescue URI::InvalidURIError
      nil
    end

    def expo_browser_host(hostname)
      # Ruby URI preserves escaped hosts while browsers decode them before
      # comparing origins. Decode the ASCII subset here; stdlib has no IDNA
      # equivalent, so reject escaped non-ASCII hosts instead of miscomparing.
      hostname = URI.decode_uri_component(hostname) if hostname.include?("%")
      return unless hostname.ascii_only?

      if hostname.include?(":")
        address = IPAddr.new(hostname)
        return unless address.ipv6?

        return "[#{address}]"
      end

      return if hostname.match?(/[\x00-\x20\x7f#%\/:<>?@\[\]\\^|]/)

      return hostname.downcase unless expo_ipv4_candidate?(hostname)

      expo_browser_ipv4(hostname)
    rescue IPAddr::InvalidAddressError
      nil
    end

    def expo_ipv4_candidate?(hostname)
      last_part = hostname.delete_suffix(".").split(".").last
      last_part && (!expo_ipv4_number(last_part).nil? || last_part.match?(/\A[0-9]+\z/))
    end

    def expo_browser_ipv4(hostname)
      parts = hostname.delete_suffix(".").split(".", -1)
      return if parts.empty? || parts.length > 4

      numbers = parts.map { |part| expo_ipv4_number(part) }
      return if numbers.any?(&:nil?)
      return if numbers[0...-1].any? { |number| number > 255 }
      return if numbers.last >= 256**(5 - numbers.length)

      value = numbers.last
      numbers[0...-1].each_with_index do |number, index|
        value += number * 256**(3 - index)
      end
      [24, 16, 8, 0].map { |shift| (value >> shift) & 255 }.join(".")
    end

    def expo_ipv4_number(part)
      return if part.empty?

      base = 10
      digits = part
      if part.match?(/\A0x/i)
        base = 16
        digits = part[2..]
      elsif part.length >= 2 && part.start_with?("0")
        base = 8
        digits = part[1..]
      end
      return 0 if digits.empty?

      pattern = {8 => /\A[0-7]+\z/, 10 => /\A[0-9]+\z/, 16 => /\A[0-9a-f]+\z/i}.fetch(base)
      return unless digits.match?(pattern)

      digits.to_i(base)
    end

    def expo_inject_cookie_into_deep_link(ctx)
      location = ctx.response_headers["location"]
      cookie = ctx.response_headers["set-cookie"]
      return unless location && cookie
      return if location.include?("/oauth-proxy-callback")

      uri = URI.parse(location)
      return if %w[http https].include?(uri.scheme)
      return unless ctx.context.trusted_origin?(location)

      query = Rack::Utils.parse_query(uri.query)
      query["cookie"] = cookie
      uri.query = URI.encode_www_form(query)
      ctx.set_header("location", uri.to_s)
    rescue URI::InvalidURIError
      nil
    end

    def expo_development_environment?
      [ENV["RACK_ENV"], ENV["RAILS_ENV"], ENV["APP_ENV"]].include?("development")
    end
  end
end
