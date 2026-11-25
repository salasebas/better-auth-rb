# frozen_string_literal: true

require "uri"
require "rack/request"

module BetterAuth
  module URLHelpers
    URI_PARSER = URI::RFC2396_Parser.new

    module_function

    def encode_uri_component(value)
      URI_PARSER.escape(value, /[^a-zA-Z0-9_.!~*'()-]/)
    end

    def valid_proxy_header?(header, type)
      value = header.to_s
      return false if value.strip.empty?

      case type.to_sym
      when :proto
        ["http", "https"].include?(value)
      when :host
        return false if value.match?(/\.\.|\0|\s|\A[.]|[<>'"]|javascript:|file:|data:/i)
        return false if value.match?(%r{[/\\]})

        patterns = [
          /\A[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*(:[0-9]{1,5})?\z/,
          /\A(\d{1,3}\.){3}\d{1,3}(:[0-9]{1,5})?\z/,
          /\A\[[0-9a-fA-F:]+\](:[0-9]{1,5})?\z/,
          /\Alocalhost(:[0-9]{1,5})?\z/i
        ]
        patterns.any? { |pattern| value.match?(pattern) }
      else
        false
      end
    end

    def matches_host_pattern?(host, pattern)
      return false if host.to_s.empty? || pattern.to_s.empty?

      normalized_host = normalize_host_pattern_value(host)
      normalized_pattern = normalize_host_pattern_value(pattern)
      Configuration.wildcard_match?(normalized_pattern, normalized_host)
    end

    def host_from_source(source, trusted_proxy_headers: false)
      headers = headers_from_source(source)
      if trusted_proxy_headers
        forwarded_host = header_value(headers, "x-forwarded-host")
        return forwarded_host if forwarded_host && valid_proxy_header?(forwarded_host, :host)
      end

      host = header_value(headers, "host")
      return host if host && valid_proxy_header?(host, :host)

      if source.is_a?(Rack::Request::Helpers)
        authority = source.server_authority
        return uri_host("#{rack_scheme(source)}://#{authority}") if valid_proxy_header?(authority, :host)
        return
      end

      uri_host(source_url(source))
    end

    def protocol_from_source(source, config_protocol: nil, trusted_proxy_headers: false)
      return config_protocol if ["http", "https"].include?(config_protocol)

      headers = headers_from_source(source)
      if trusted_proxy_headers
        forwarded_proto = header_value(headers, "x-forwarded-proto")
        return forwarded_proto if forwarded_proto && valid_proxy_header?(forwarded_proto, :proto)
      end

      protocol = if source.is_a?(Rack::Request::Helpers)
        rack_scheme(source)
      else
        uri_scheme(source_url(source))
      end
      return protocol if ["http", "https"].include?(protocol)

      host = host_from_source(source, trusted_proxy_headers: trusted_proxy_headers)
      return "http" if host && loopback_for_dev_scheme?(host)

      "https"
    end

    def resolve_base_url(config, base_path, source = nil, load_env: true, trusted_proxy_headers: false)
      if dynamic_config?(config)
        return resolve_dynamic_base_url(config, source, base_path, trusted_proxy_headers: trusted_proxy_headers) if source
        fallback = dynamic_option(config, :fallback)
        return with_path(fallback, base_path) if fallback && !fallback.empty?

        return load_env ? env_base_url(base_path) : nil
      end

      return with_path(config, base_path) if config.is_a?(String) && !config.empty?

      load_env ? env_base_url(base_path) : nil
    end

    def resolve_dynamic_base_url(config, source, base_path, trusted_proxy_headers: false)
      host = host_from_source(source, trusted_proxy_headers: trusted_proxy_headers)
      fallback = dynamic_option(config, :fallback)
      fallback = nil if fallback == ""
      raise Error, "Could not determine host from request headers. Please provide a fallback URL in your baseURL config." unless host || fallback

      allowed_hosts = allowed_hosts(config)
      if host && allowed_hosts.any? { |pattern| matches_host_pattern?(host, pattern) }
        protocol = protocol_from_source(source, config_protocol: dynamic_option(config, :protocol), trusted_proxy_headers: trusted_proxy_headers)
        return with_path("#{protocol}://#{host}", base_path)
      end

      return with_path(fallback, base_path) if fallback

      raise Error, "Host \"#{host}\" is not in the allowed hosts list. Allowed hosts: #{allowed_hosts.join(", ")}. Add this host to your allowedHosts config or provide a fallback URL."
    end

    def with_path(url, path = "/api/auth")
      parsed = parse_url(url)
      raise Error, "Invalid base URL: #{url}. Please provide a valid base URL." unless parsed
      raise Error, "Invalid base URL: #{url}. URL must include 'http://' or 'https://'" unless ["http", "https"].include?(parsed.scheme)

      current_path = parsed.path.to_s.gsub(%r{/+\z}, "")
      return url.to_s if !current_path.empty? && current_path != "/"

      trimmed = url.to_s.gsub(%r{/+\z}, "")
      return trimmed if path.to_s.empty? || path == "/"

      suffix = path.start_with?("/") ? path : "/#{path}"
      "#{trimmed}#{suffix}"
    end

    def origin(url)
      parsed = parse_url(url)
      return unless parsed && ["http", "https"].include?(parsed.scheme)

      Configuration.origin_for(parsed).downcase
    end

    def uri_host(url)
      parsed = parse_url(url)
      return unless parsed&.host

      default_port = (parsed.scheme == "http" && parsed.port == 80) || (parsed.scheme == "https" && parsed.port == 443)
      default_port ? parsed.host : "#{parsed.host}:#{parsed.port}"
    end

    def uri_scheme(url)
      parse_url(url)&.scheme
    end

    def parse_url(url)
      parsed = URI.parse(url.to_s)
      return unless parsed.scheme
      if parsed.is_a?(URI::HTTP)
        return if parsed.host.to_s.empty? || !parsed.port.between?(0, 65_535)
      end

      parsed
    rescue URI::InvalidURIError
      nil
    end

    def normalize_host_pattern_value(value)
      value.to_s.sub(%r{\Ahttps?://}i, "").split("/").first.to_s.downcase
    end

    def headers_from_source(source)
      return {} unless source
      return rack_request_headers(source) if source.respond_to?(:get_header)
      return source.headers if source.respond_to?(:headers)
      return source if source.is_a?(Hash)

      {}
    end

    def header_value(headers, key)
      if headers.respond_to?(:get)
        headers.get(key)
      else
        headers[key] || headers[key.to_s] || headers[key.to_s.downcase] || headers[key.to_s.upcase] || headers[key.tr("-", "_").upcase]
      end
    end

    def source_url(source)
      return source.url if source.respond_to?(:url)

      source.get_header("REQUEST_URI") if source.respond_to?(:get_header)
    end

    def rack_scheme(source)
      (source.get_header("HTTPS") == "on") ? "https" : source.get_header("rack.url_scheme")
    end

    def dynamic_config?(config)
      config.is_a?(Hash) && allowed_hosts(config).is_a?(Array)
    end

    def allowed_hosts(config)
      dynamic_option(config, :allowed_hosts) || dynamic_option(config, :allowedHosts)
    end

    def dynamic_option(config, key)
      config.fetch(key) { config[key.to_s] }
    end

    def env_base_url(base_path)
      base_url = ENV["BASE_URL"]
      url = [
        Env.get("BETTER_AUTH_URL"),
        ENV["NEXT_PUBLIC_BETTER_AUTH_URL"],
        ENV["PUBLIC_BETTER_AUTH_URL"],
        ENV["NUXT_PUBLIC_BETTER_AUTH_URL"],
        ENV["NUXT_PUBLIC_AUTH_URL"],
        (base_url unless base_url == "/")
      ].find { |value| value && !value.empty? }
      with_path(url, base_path) if url
    end

    def loopback_for_dev_scheme?(host)
      hostname = host.to_s.sub(/:\d+\z/, "").sub(/\A\[/, "").sub(/\]\z/, "").downcase
      hostname == "localhost" || hostname.end_with?(".localhost") || hostname == "::1" || hostname.start_with?("127.")
    end

    def rack_request_headers(source)
      {
        "x-forwarded-host" => source.get_header("HTTP_X_FORWARDED_HOST"),
        "x-forwarded-proto" => source.get_header("HTTP_X_FORWARDED_PROTO"),
        "host" => source.get_header("HTTP_HOST")
      }.compact
    end
  end
end
