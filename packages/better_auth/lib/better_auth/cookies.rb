# frozen_string_literal: true

require "json"
require "time"
require "uri"

module BetterAuth
  module Cookies
    SECURE_COOKIE_PREFIX = "__Secure-"
    HOST_COOKIE_PREFIX = "__Host-"
    COOKIE_NAME_PATTERN = /\A[\x21\x23-\x27\x2A\x2B\x2D\x2E\x30-\x39\x41-\x5A\x5E\x5F\x60\x61-\x7A\x7C\x7E]+\z/
    COOKIE_VALUE_PATTERN = /\A[\x20\x21\x23-\x3A\x3C-\x5B\x5D-\x7E]*\z/
    COOKIE_OPTION_KEYS = {"max-age" => :max_age, "expires" => :expires, "domain" => :domain, "path" => :path,
                          "secure" => :secure, "httponly" => :http_only, "partitioned" => :partitioned, "samesite" => :same_site}.freeze

    Cookie = Struct.new(:name, :attributes) do
      alias_method :options, :attributes
    end

    module_function

    def get_cookies(options)
      max_age = cache_max_age(options.session.dig(:cookie_cache, :max_age))
      {
        session_token: create_cookie(options, "session_token", max_age: options.session[:expires_in] || 60 * 60 * 24 * 7),
        session_data: create_cookie(options, "session_data", max_age: max_age),
        account_data: create_cookie(options, "account_data", max_age: max_age),
        dont_remember: create_cookie(options, "dont_remember")
      }
    end

    def cache_max_age(max_age, default: 60 * 5)
      (max_age && max_age != 0) ? max_age : default
    end

    def create_cookie(options, cookie_name, override_attributes = {})
      advanced = options.advanced || {}
      secure = if advanced.key?(:use_secure_cookies)
        advanced[:use_secure_cookies]
      elsif options.base_url.to_s.start_with?("https://")
        true
      else
        production_environment?
      end
      cross_subdomain = advanced.dig(:cross_subdomain_cookies, :enabled)
      domain = if cross_subdomain
        advanced.dig(:cross_subdomain_cookies, :domain) || begin
          uri = URI.parse(options.base_url.to_s)
          uri.host unless uri.host.to_s.empty?
        end
      end
      custom = advanced.dig(:cookies, cookie_name.to_sym) || {}
      prefix = advanced[:cookie_prefix] || "better-auth"
      name = custom[:name] || "#{prefix}.#{cookie_name}"
      attributes = {
        secure: !!secure,
        same_site: "lax",
        path: "/",
        http_only: true
      }
      attributes[:domain] = domain if domain
      attributes = attributes
        .merge(advanced[:default_cookie_attributes] || {})
        .merge(override_attributes || {})
        .merge(custom[:attributes] || {})
        .compact

      cookie_prefix = secure ? SECURE_COOKIE_PREFIX : ""
      Cookie.new(name: "#{cookie_prefix}#{name}", attributes: attributes)
    end

    def parse_cookies(cookie_header)
      header = cookie_header.to_s
      return {} if header.length < 2

      header.split(";", -1).each_with_object({}) do |pair, result|
        separator = pair.index("=")
        next unless separator

        name = trim_cookie_ows(pair[0...separator])
        value = unquote_cookie_value(trim_cookie_ows(pair[(separator + 1)..]))
        next unless COOKIE_NAME_PATTERN.match?(name) && COOKIE_VALUE_PATTERN.match?(value)

        result[name] = decode_cookie_value(value)
      end
    end

    def split_set_cookie_header(header)
      Array(header).flat_map do |value|
        value.to_s.lines(chomp: true).flat_map do |line|
          line.split(/,(?=[ \t]*[!#$%&'*+\-.^_`|~0-9A-Za-z]+=)/).map(&:strip)
        end
      end.reject(&:empty?)
    end

    def parse_set_cookie(line)
      first, *attributes = line.to_s.split(";").map(&:strip)
      name, value = first.to_s.split("=", 2)
      return if name.to_s.empty?

      {
        name: name,
        value: decode_cookie_value(unquote_cookie_value(value.to_s)),
        attributes: attributes.each_with_object({}) do |attribute, result|
          key, raw = attribute.split("=", 2)
          key = key.to_s.strip.downcase
          next if key.empty?

          raw = raw.to_s.strip
          raw = nil if raw.empty?
          result[key] = case key
          when "max-age" then parse_cookie_integer(raw)
          when "expires" then parse_cookie_expiry(raw)
          when "secure", "httponly", "partitioned" then true
          when "samesite" then raw&.downcase
          when "domain", "path" then raw
          else raw || true
          end
        end
      }
    end

    def to_cookie_options(attributes)
      attributes.slice(*COOKIE_OPTION_KEYS.keys).transform_keys(COOKIE_OPTION_KEYS).compact
    end

    def apply_set_cookies(cookie_header, set_cookie_values)
      cookies = parse_cookies(cookie_header)
      split_set_cookie_header(set_cookie_values).each do |line|
        cookie = parse_set_cookie(line)
        next unless cookie && COOKIE_NAME_PATTERN.match?(cookie[:name])

        cookies[cookie[:name]] = cookie[:value]
      end
      serialize_request_cookies(cookies)
    end

    def set_request_cookie(cookie_header, name, value)
      cookies = parse_cookies(cookie_header)
      cookie_name = name.to_s
      cookies[cookie_name] = value.to_s if COOKIE_NAME_PATTERN.match?(cookie_name)
      serialize_request_cookies(cookies)
    end

    def strip_secure_cookie_prefix(name)
      name = name.to_s
      return name.delete_prefix(SECURE_COOKIE_PREFIX) if name.start_with?(SECURE_COOKIE_PREFIX)

      name.delete_prefix(HOST_COOKIE_PREFIX)
    end

    def get_session_cookie(request_or_cookie_header, config = {})
      cookie_header = header_value(request_or_cookie_header)
      return nil if cookie_header.to_s.empty?

      parsed = parse_cookies(cookie_header)
      cookie_name = config[:cookie_name] || "session_token"
      cookie_prefix = config[:cookie_prefix] || "better-auth"
      ["#{cookie_prefix}.#{cookie_name}", "#{cookie_prefix}-#{cookie_name}"].each do |name|
        value = parsed["#{SECURE_COOKIE_PREFIX}#{name}"] || parsed[name]
        return value unless value.to_s.empty?
      end
      nil
    end

    def set_session_cookie(ctx, session, dont_remember_me = nil, overrides = {})
      dont_remember_me = dont_remember?(ctx) if dont_remember_me.nil?
      set_session_token(ctx, session.fetch(:session).fetch("token"), dont_remember_me, overrides)

      if dont_remember_me
        dont_remember_cookie = ctx.context.auth_cookies[:dont_remember]
        ctx.set_signed_cookie(dont_remember_cookie.name, "true", ctx.context.secret, dont_remember_cookie.attributes)
      end

      set_cookie_cache(ctx, session, dont_remember_me)
      ctx.context.set_new_session(session) if ctx.context.respond_to?(:set_new_session)
    end

    def set_session_token(ctx, token, dont_remember_me, overrides = {})
      cookie = ctx.context.auth_cookies[:session_token]
      max_age = dont_remember_me ? nil : ctx.context.session_config[:expires_in]
      ctx.set_signed_cookie(cookie.name, token, ctx.context.secret, cookie.attributes.merge(max_age: max_age).merge(overrides || {}))
    end

    def set_cookie_cache(ctx, session, dont_remember_me)
      config = ctx.context.session_config[:cookie_cache] || {}
      return unless config[:enabled]

      cookie = ctx.context.auth_cookies[:session_data]
      max_age = cookie.attributes[:max_age] unless dont_remember_me
      data = filtered_cache_data(ctx, session)
      strategy = config[:strategy] || "compact"
      secret = (strategy.to_s == "jwe") ? ctx.context.secret_config : ctx.context.secret
      default_max_age = compact_cache?(strategy) ? 60 : 60 * 5
      value = encode_cookie_cache(data, secret, strategy: strategy, max_age: cache_max_age(max_age, default: default_max_age))
      attributes = cookie.attributes.merge(max_age: max_age)
      store = SessionStore.new(cookie.name, attributes, ctx)
      store.set_cookies(store.chunk(value))

      sync_account_cookie(ctx, session)
    end

    def set_account_cookie(ctx, account_data)
      return unless ctx.context.options.account[:store_account_cookie]

      cookie = ctx.context.auth_cookies[:account_data]
      attributes = cookie.attributes.merge(max_age: cookie.attributes[:max_age] || 60 * 5)
      value = Crypto.symmetric_encode_jwt(stringify_keys(account_data), ctx.context.secret_config, "better-auth-account", expires_in: attributes[:max_age])
      store = SessionStore.new(cookie.name, attributes, ctx, store_name: "Account")
      store.set_cookies(store.chunk(value))
    end

    def get_account_cookie(ctx)
      cookie = ctx.context.auth_cookies[:account_data]
      value = SessionStore.get_chunked_cookie(ctx, cookie.name)
      return nil unless value

      Crypto.symmetric_decode_jwt(value, ctx.context.secret_config, "better-auth-account")
    end

    def sync_account_cookie(ctx, session)
      return unless ctx.context.options.account[:store_account_cookie]

      cookie = ctx.context.auth_cookies[:account_data]
      return if pending_set_cookie?(ctx, cookie.name)

      account_data = get_account_cookie(ctx)
      return unless account_data

      if account_matches_session_user?(ctx, account_data, session.fetch(:user).fetch("id"))
        set_account_cookie(ctx, account_data)
      else
        expire_cookie(ctx, cookie)
        store = SessionStore.new(cookie.name, cookie.attributes, ctx)
        store.set_cookies(store.clean)
      end
    end

    def account_matches_session_user?(ctx, account, user_id)
      !ctx.context.options.database || account["userId"] == user_id
    end

    def get_cookie_cache(request_or_cookie_header, secret: nil, strategy: "compact", version: nil, cookie_prefix: "better-auth", cookie_name: "session_data", is_secure: nil, cookie_full_name: nil, include_expiry: false)
      cookie_header = header_value(request_or_cookie_header)
      return nil if cookie_header.to_s.empty?

      parsed = parse_cookies(cookie_header)
      name = if cookie_full_name
        cookie_full_name
      elsif is_secure.nil?
        production_environment? ? "#{SECURE_COOKIE_PREFIX}#{cookie_prefix}.#{cookie_name}" : "#{cookie_prefix}.#{cookie_name}"
      else
        secure_prefix = is_secure ? SECURE_COOKIE_PREFIX : ""
        "#{secure_prefix}#{cookie_prefix}.#{cookie_name}"
      end
      raw = parsed[name]
      raw = SessionStore.chunked_value(parsed, name) if raw.to_s.empty?
      return nil if raw.to_s.empty?

      secret = ENV["BETTER_AUTH_SECRET"] if secret.nil? || secret == ""
      if secret.nil? || secret == ""
        raise Error, "getCookieCache requires a secret to be provided. Either pass it as an option or set the BETTER_AUTH_SECRET environment variable"
      end

      payload = decode_cookie_cache(raw, secret, strategy: strategy, include_expiry: include_expiry)
      return nil unless session_cache_payload?(payload)
      return nil if embedded_session_expired?(payload["session"])
      return nil if cache_version_configured?(version) && !cookie_cache_version_matches?(version, payload)

      payload
    end

    def read_session_cache(ctx, config, use_cache:)
      cookie = ctx.context.auth_cookies[:session_data]
      raw = SessionStore.get_chunked_cookie(ctx, cookie.name)
      return nil if raw.to_s.empty?

      strategy = config[:strategy] || "compact"
      payload = if compact_cache?(strategy)
        envelope = parse_compact_cache(raw)
        return nil unless envelope

        verify_compact_cache(envelope, ctx.context.secret)
      else
        secret = (strategy.to_s == "jwe") ? ctx.context.secret_config : ctx.context.secret
        decoded = decode_cookie_cache(raw, secret, strategy: strategy)
        decoded&.merge("expiresAt" => decoded["exp"] ? decoded["exp"].to_i * 1000 : current_millis)
      end

      unless session_cache_payload?(payload)
        expire_cookie(ctx, cookie)
        return nil
      end
      return nil unless use_cache

      if !cookie_cache_version_matches?(config[:version], payload) ||
          cache_window_expired?(payload) || embedded_session_expired?(payload["session"])
        expire_cookie(ctx, cookie)
        return nil
      end
      payload
    end

    def expire_cookie(ctx, cookie)
      remove_set_cookie_entries(ctx, cookie.name)
      ctx.set_cookie(cookie.name, "", cookie.attributes.merge(max_age: 0))
    end

    def delete_session_cookie(ctx, skip_dont_remember_me: false)
      expire_cookie(ctx, ctx.context.auth_cookies[:session_token])
      expire_cookie(ctx, ctx.context.auth_cookies[:session_data])
      expire_cookie(ctx, ctx.context.auth_cookies[:account_data]) if ctx.context.options.account[:store_account_cookie]

      if ctx.context.options.account[:store_account_cookie]
        account_store = SessionStore.new(ctx.context.auth_cookies[:account_data].name, ctx.context.auth_cookies[:account_data].attributes, ctx)
        account_store.set_cookies(account_store.clean)
      end

      store = SessionStore.new(ctx.context.auth_cookies[:session_data].name, ctx.context.auth_cookies[:session_data].attributes, ctx)
      store.set_cookies(store.clean)
      expire_cookie(ctx, ctx.context.auth_cookies[:dont_remember]) unless skip_dont_remember_me
    end

    def dont_remember?(ctx)
      cookie = ctx.context.auth_cookies[:dont_remember]
      ctx.get_signed_cookie(cookie.name, ctx.context.secret) == "true"
    end

    def encode_cookie_cache(data, secret, strategy:, max_age:)
      case strategy.to_s
      when "jwt"
        Crypto.sign_jwt(data, secret, expires_in: max_age)
      when "jwe"
        Crypto.symmetric_encode_jwt(data, secret, "better-auth-session", expires_in: max_age)
      else
        expires_at = current_millis + (max_age.to_i * 1000)
        signed = data.merge("expiresAt" => expires_at)
        signature = Crypto.hmac_signature(JSON.generate(signed), secret, encoding: :base64url)
        Crypto.base64url_encode(JSON.generate({"session" => data, "expiresAt" => expires_at, "signature" => signature}))
      end
    end

    def decode_cookie_cache(value, secret, strategy:, include_expiry: false)
      case strategy.to_s
      when "jwt"
        Crypto.verify_jwt(value, secret)
      when "jwe"
        Crypto.symmetric_decode_jwt(value, secret, "better-auth-session")
      else
        envelope = parse_compact_cache(value)
        return nil unless envelope

        payload = verify_compact_cache(envelope, secret)
        return nil if !payload || cache_window_expired?(payload)

        include_expiry ? payload : envelope["session"]
      end
    rescue ArgumentError, JWT::DecodeError
      nil
    end

    def compact_cache?(strategy)
      !%w[jwt jwe].include?(strategy.to_s)
    end

    def parse_compact_cache(raw)
      parsed = JSON.parse(Crypto.base64url_decode(raw))
      parsed if parsed.is_a?(Hash)
    rescue JSON::ParserError, ArgumentError
      nil
    end

    def verify_compact_cache(envelope, secret)
      data = envelope["session"]
      return nil unless data.is_a?(Hash)

      signed = data.merge("expiresAt" => envelope["expiresAt"])
      signed if Crypto.verify_hmac_signature(JSON.generate(signed), envelope["signature"], secret, encoding: :base64url)
    end

    def session_cache_payload?(payload)
      payload.is_a?(Hash) && payload["session"].is_a?(Hash) && payload["user"].is_a?(Hash)
    end

    def cache_window_expired?(payload)
      expiry = payload["expiresAt"]
      expiry.is_a?(Numeric) && expiry < current_millis
    end

    def filtered_cache_data(ctx, session)
      {
        "session" => stringify_keys(Schema.parse_output(ctx.context.options, "session", stringify_keys(session.fetch(:session)))),
        "user" => stringify_keys(Schema.parse_output(ctx.context.options, "user", stringify_keys(session.fetch(:user)))),
        "updatedAt" => current_millis,
        "version" => cookie_cache_version(
          ctx.context.session_config.dig(:cookie_cache, :version),
          session.fetch(:session),
          session.fetch(:user)
        )
      }
    end

    def embedded_session_expired?(session)
      expires_at = session["expiresAt"] || session[:expiresAt] || session["expires_at"] || session[:expires_at]
      normalized = Session.normalize_time(expires_at)
      normalized && normalized < Time.now
    rescue ArgumentError
      true
    end

    def remove_set_cookie_entries(ctx, cookie_name)
      header = ctx.response_headers["set-cookie"]
      return unless header

      exact = "#{cookie_name}="
      chunk = "#{cookie_name}."
      survivors = split_set_cookie_header(header).reject do |entry|
        entry.start_with?(exact, chunk)
      end
      if survivors.empty?
        ctx.response_headers.delete("set-cookie")
      else
        ctx.response_headers["set-cookie"] = survivors.join("\n")
      end
    end

    def pending_set_cookie?(ctx, cookie_name)
      exact = "#{cookie_name}="
      chunk = "#{cookie_name}."
      split_set_cookie_header(ctx.response_headers["set-cookie"]).any? do |entry|
        entry.start_with?(exact, chunk)
      end
    end

    def decode_cookie_value(value)
      decoded = URI.decode_uri_component(value)
      decoded.valid_encoding? ? decoded : value
    rescue ArgumentError
      value
    end

    def parse_cookie_integer(value)
      value.to_s.lstrip[/\A[+-]?\d+/]&.to_i
    end

    def parse_cookie_expiry(value)
      Time.parse(value) if value
    rescue ArgumentError
      nil
    end

    def trim_cookie_ows(value)
      value.sub(/\A[ \t]*/, "").sub(/[ \t]*\z/, "")
    end

    def unquote_cookie_value(value)
      return value unless value.length >= 2 && value.start_with?("\"") && value.end_with?("\"")

      value[1...-1]
    end

    def encode_cookie_value(value)
      value.to_s.encode(Encoding::UTF_8).bytes.map do |byte|
        if byte.between?(48, 57) || byte.between?(65, 90) || byte.between?(97, 122) || [33, 39, 40, 41, 42, 45, 46, 95, 126].include?(byte)
          byte.chr
        else
          "%#{byte.to_s(16).upcase.rjust(2, "0")}"
        end
      end.join
    end

    def serialize_request_cookies(cookies)
      cookies.map { |key, value| "#{key}=#{encode_cookie_value(value)}" }.join("; ")
    end

    def header_value(request_or_cookie_header)
      return request_or_cookie_header.headers["cookie"] if request_or_cookie_header.respond_to?(:headers)
      return request_or_cookie_header.get_header("HTTP_COOKIE") if request_or_cookie_header.respond_to?(:get_header)

      request_or_cookie_header.to_s
    end

    def cookie_cache_version(config, session, user)
      return "1" unless cache_version_configured?(config)
      return config.to_s unless config.respond_to?(:call)

      config.call(session, user).to_s
    end

    def cache_version_configured?(version)
      version && version != ""
    end

    def cookie_cache_version_matches?(config, payload)
      version = payload["version"]
      version = "1" if version.nil? || version == ""
      version == cookie_cache_version(config, payload.fetch("session"), payload.fetch("user"))
    end

    def current_millis
      (Time.now.to_f * 1000).to_i
    end

    def stringify_keys(value)
      return value.each_with_object({}) { |(key, object_value), result| result[key.to_s] = stringify_keys(object_value) } if value.is_a?(Hash)
      return value.map { |entry| stringify_keys(entry) } if value.is_a?(Array)

      value
    end

    def production_environment?
      ENV["RACK_ENV"] == "production" || ENV["RAILS_ENV"] == "production" || ENV["APP_ENV"] == "production"
    end
  end
end
