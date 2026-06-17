# frozen_string_literal: true

require "json"
require "rack/utils"
require "uri"

module BetterAuth
  module Plugins
    module_function

    def oauth_proxy(options = {})
      config = {max_age: 60}.merge(normalize_hash(options))

      Plugin.new(
        id: "oauth-proxy",
        endpoints: {
          oauth_proxy: oauth_proxy_endpoint(config)
        },
        hooks: {
          before: [
            {
              matcher: ->(ctx) { oauth_proxy_sign_in_path?(ctx.path) },
              handler: ->(ctx) { oauth_proxy_before_sign_in(ctx, config) }
            },
            {
              matcher: ->(ctx) { oauth_proxy_callback_path?(ctx.path) },
              handler: ->(ctx) { oauth_proxy_restore_state_package(ctx, config) }
            }
          ],
          after: [
            {
              matcher: ->(ctx) { oauth_proxy_sign_in_path?(ctx.path) },
              handler: ->(ctx) { oauth_proxy_after_sign_in(ctx, config) }
            },
            {
              matcher: ->(ctx) { oauth_proxy_callback_path?(ctx.path) },
              handler: ->(ctx) { oauth_proxy_after_callback(ctx, config) }
            }
          ]
        },
        options: config
      )
    end

    def oauth_proxy_endpoint(config)
      Endpoint.new(
        path: "/oauth-proxy-callback",
        method: "GET",
        metadata: {
          openapi: {
            operationId: "oauthProxyCallback",
            description: "OAuth Proxy Callback",
            parameters: [
              {in: "query", name: "callbackURL", required: true, schema: {type: "string", format: "uri"}},
              {in: "query", name: "cookies", required: true, schema: {type: "string"}}
            ],
            responses: {
              "302" => {description: "Redirects to the callback URL"}
            }
          }
        }
      ) do |ctx|
        query = normalize_hash(ctx.query)
        callback_url = query[:callback_url] || "/"
        oauth_proxy_validate_callback!(ctx, callback_url)

        decrypted = Crypto.symmetric_decrypt(key: oauth_proxy_secret(ctx, config), data: query[:cookies].to_s)
        raise ctx.redirect(oauth_proxy_error_url(ctx, "OAuthProxy - Invalid cookies or secret")) unless decrypted

        payload = JSON.parse(decrypted)
        cookies = payload["cookies"]
        timestamp = payload["timestamp"]
        unless cookies.is_a?(String) && timestamp.is_a?(Numeric)
          raise ctx.redirect(oauth_proxy_error_url(ctx, "OAuthProxy - Invalid payload structure"))
        end

        age = ((Time.now.to_f * 1000) - timestamp.to_f) / 1000
        if age > config[:max_age].to_i || age < -10
          raise ctx.redirect(oauth_proxy_error_url(ctx, "OAuthProxy - Payload expired or invalid"))
        end

        oauth_proxy_parse_set_cookie(cookies).each do |cookie|
          ctx.set_cookie(cookie[:name], cookie[:value], cookie[:options])
        end
        raise ctx.redirect(callback_url)
      rescue JSON::ParserError
        raise ctx.redirect(oauth_proxy_error_url(ctx, "OAuthProxy - Invalid payload format"))
      end
    end

    def oauth_proxy_before_sign_in(ctx, config)
      return if oauth_proxy_skip?(ctx, config)
      return unless ctx.body.is_a?(Hash)

      original_callback = ctx.body["callbackURL"] || ctx.body["callbackUrl"] || ctx.body["callback_url"] || ctx.body[:callbackURL] || ctx.body[:callback_url] || ctx.context.base_url
      current = oauth_proxy_current_uri(ctx, config)
      callback = "#{oauth_proxy_strip_trailing(current.origin)}#{ctx.context.options.base_path}/oauth-proxy-callback?callbackURL=#{URI.encode_www_form_component(original_callback)}"
      ctx.body = ctx.body.merge("callbackURL" => callback, :callback_url => callback)
      nil
    end

    def oauth_proxy_restore_state_package(ctx, config)
      state = fetch_value(ctx.query, "state") || fetch_value(ctx.body, "state")
      return if state.to_s.empty?

      decrypted = Crypto.symmetric_decrypt(key: oauth_proxy_secret(ctx, config), data: state.to_s)
      return unless decrypted

      package = JSON.parse(decrypted)
      return unless package["isOAuthProxy"] && package["state"] && package["stateCookie"]

      cookie = ctx.context.create_auth_cookie("oauth_state")
      current_cookie = ctx.headers["cookie"].to_s
      restored_cookie = "#{cookie.name}=#{package["stateCookie"]}"
      ctx.headers["cookie"] = current_cookie.empty? ? restored_cookie : "#{current_cookie}; #{restored_cookie}"
      ctx.query = ctx.query.merge(:state => package["state"], "state" => package["state"])
      ctx.body = ctx.body.merge(:state => package["state"], "state" => package["state"]) if ctx.body.is_a?(Hash)
      nil
    rescue JSON::ParserError
      nil
    end

    def oauth_proxy_after_sign_in(ctx, config)
      return if oauth_proxy_skip?(ctx, config)
      return unless ctx.context.options.account[:store_state_strategy].to_s == "cookie"
      return unless ctx.returned.is_a?(Hash)

      provider_url = fetch_value(ctx.returned, "url").to_s
      return if provider_url.empty?

      uri = URI.parse(provider_url)
      params = Rack::Utils.parse_query(uri.query)
      original_state = params["state"]
      return if original_state.to_s.empty?

      state_cookie = oauth_proxy_state_cookie_value(ctx)
      return if state_cookie.to_s.empty?

      encrypted_package = Crypto.symmetric_encrypt(
        key: oauth_proxy_secret(ctx, config),
        data: JSON.generate({
          state: original_state,
          stateCookie: state_cookie,
          isOAuthProxy: true
        })
      )
      params["state"] = encrypted_package
      uri.query = URI.encode_www_form(params)

      response = ctx.returned.dup
      if response.key?(:url)
        response[:url] = uri.to_s
      else
        response["url"] = uri.to_s
      end
      ctx.returned = response
      ctx.json(response)
    rescue URI::InvalidURIError
      nil
    end

    def oauth_proxy_after_callback(ctx, config)
      location = ctx.response_headers["location"]
      return unless location.to_s.include?("/oauth-proxy-callback?callbackURL")
      return unless location.to_s.start_with?("http")

      location_uri = URI.parse(location)
      production = oauth_proxy_production_uri(ctx, config)
      if location_uri.origin == production.origin
        original = Rack::Utils.parse_query(location_uri.query).fetch("callbackURL", nil)
        oauth_proxy_set_location(ctx, original) if original
        return nil
      end

      set_cookie = ctx.response_headers["set-cookie"]
      return if set_cookie.to_s.empty?

      encrypted = Crypto.symmetric_encrypt(
        key: oauth_proxy_secret(ctx, config),
        data: JSON.generate({
          cookies: set_cookie,
          timestamp: (Time.now.to_f * 1000).to_i
        })
      )
      separator = location.include?("?") ? "&" : "?"
      oauth_proxy_set_location(ctx, "#{location}#{separator}cookies=#{URI.encode_www_form_component(encrypted)}")
      nil
    rescue URI::InvalidURIError
      nil
    end

    def oauth_proxy_state_cookie_value(ctx)
      cookie = ctx.context.create_auth_cookie("oauth_state")
      parsed = oauth_proxy_parse_set_cookie(ctx.response_headers["set-cookie"])
      exact = parsed.find { |entry| entry[:name] == cookie.name || entry[:name] == Cookies.strip_secure_cookie_prefix(cookie.name) }
      exact && exact[:value]
    end

    def oauth_proxy_secret(ctx, config)
      config[:secret] || ctx.context.secret_config
    end

    def oauth_proxy_sign_in_path?(path)
      path.to_s.start_with?("/sign-in/social", "/sign-in/oauth2")
    end

    def oauth_proxy_callback_path?(path)
      path.to_s.start_with?("/callback", "/oauth2/callback")
    end

    def oauth_proxy_skip?(ctx, config)
      current = oauth_proxy_current_uri(ctx, config)
      production = oauth_proxy_production_uri(ctx, config)
      current.origin == production.origin
    rescue URI::InvalidURIError
      false
    end

    def oauth_proxy_current_uri(ctx, config)
      URI.parse((config[:current_url] || ctx.context.options.base_url || ctx.context.base_url).to_s)
    end

    def oauth_proxy_production_uri(ctx, config)
      URI.parse((config[:production_url] || ctx.context.options.base_url || ctx.context.base_url).to_s)
    end

    def oauth_proxy_strip_trailing(value)
      value.to_s.sub(%r{/+\z}, "")
    end

    def oauth_proxy_validate_callback!(ctx, callback_url)
      return if callback_url.to_s.empty?
      return if ctx.context.trusted_origin?(callback_url.to_s, allow_relative_paths: true)

      raise APIError.new("FORBIDDEN", message: "Invalid callbackURL")
    end

    def oauth_proxy_error_url(ctx, message)
      base = ctx.context.options.on_api_error[:error_url] || "#{oauth_proxy_strip_trailing(ctx.context.base_url)}/error"
      uri = URI.parse(base)
      params = URI.decode_www_form(uri.query.to_s)
      params << ["error", message]
      uri.query = URI.encode_www_form(params)
      uri.to_s
    end

    def oauth_proxy_set_location(ctx, location)
      ctx.set_header("location", location)
      return unless ctx.returned.is_a?(APIError)

      headers = ctx.returned.headers.merge("location" => location)
      ctx.returned.instance_variable_set(:@headers, headers)
    end

    def oauth_proxy_parse_set_cookie(header)
      header.to_s.split(/\n|,(?=\s*[^;,]+=)/).filter_map do |line|
        parts = line.strip.split(/;\s*/)
        name, value = parts.shift.to_s.split("=", 2)
        next if name.to_s.empty?

        options = {}
        parts.each do |part|
          key, option_value = part.split("=", 2)
          case key.to_s.downcase
          when "path" then options[:path] = option_value
          when "expires" then options[:expires] = option_value
          when "samesite" then options[:same_site] = option_value
          when "httponly" then options[:http_only] = true
          when "secure" then options[:secure] = true
          when "max-age" then options[:max_age] = option_value
          end
        end
        {name: Cookies.strip_secure_cookie_prefix(name), value: URI.decode_www_form_component(value.to_s), options: options}
      end
    end
  end
end
