# frozen_string_literal: true

require "uri"

module BetterAuth
  module Plugins
    BEARER_SCHEME = "bearer "

    module_function

    def bearer(options = {})
      config = normalize_hash(options)

      Plugin.new(
        id: "bearer",
        hooks: {
          before: [
            {
              matcher: ->(ctx) { authorization_header(ctx) },
              handler: ->(ctx) { apply_bearer_token(ctx, config) }
            }
          ],
          after: [
            {
              matcher: ->(_ctx) { true },
              handler: ->(ctx) { expose_auth_token(ctx) }
            }
          ]
        },
        options: config
      )
    end

    def authorization_header(ctx)
      ctx.headers["authorization"] || ctx.headers["Authorization"]
    end

    def apply_bearer_token(ctx, config)
      auth_header = authorization_header(ctx).to_s
      return unless auth_header[0, BEARER_SCHEME.length].to_s.downcase == BEARER_SCHEME

      token = auth_header[BEARER_SCHEME.length..].to_s.strip
      return if token.empty?

      signed_token = if token.include?(".")
        normalize_signed_bearer_token(token)
      else
        sign_bearer_token(ctx, token, config)
      end
      return unless signed_token && valid_signed_token?(ctx, signed_token)

      cookie_name = ctx.context.auth_cookies[:session_token].name
      cookie = Cookies.set_request_cookie(ctx.headers["cookie"], cookie_name, signed_token)
      {context: {headers: ctx.headers.merge("cookie" => cookie)}}
    end

    def sign_bearer_token(ctx, token, config)
      return if config[:require_signature]

      signature = Crypto.hmac_signature(token, ctx.context.secret, encoding: :base64url)
      "#{token}.#{signature}"
    end

    def valid_signed_token?(ctx, signed_token)
      payload, signature = signed_token.rpartition(".").values_at(0, 2)
      return false if payload.empty? || signature.empty?

      Crypto.verify_hmac_signature(payload, signature, ctx.context.secret, encoding: :base64url)
    rescue
      false
    end

    def normalize_signed_bearer_token(token)
      token.include?("%") ? safe_decode_bearer_token(token) : safe_decode_bearer_token(safe_encode_bearer_token(token))
    end

    def safe_encode_bearer_token(token)
      URI.encode_www_form_component(token.to_s).gsub("+", "%20")
    rescue
      token.to_s
    end

    def safe_decode_bearer_token(token)
      token.to_s.gsub(/%[0-9a-fA-F]{2}/) { |encoded| encoded[1, 2].to_i(16).chr }
    rescue
      token.to_s
    end

    def bearer_session_cookie(line)
      first, *attributes = line.to_s.split(";").map(&:strip)
      name, value = first.split("=", 2)
      return unless name && value

      {
        name: name,
        value: value,
        attributes: attributes.each_with_object({}) do |attribute, result|
          key, attribute_value = attribute.split("=", 2)
          result[key.to_s.downcase] = attribute_value || true unless key.to_s.empty?
        end
      }
    end

    def expired_bearer_cookie?(cookie)
      max_age = cookie[:attributes]["max-age"]
      max_age.to_s.strip.match?(/\A[+-]?\d+\z/) && max_age.to_i == 0
    end

    def expose_auth_token(ctx)
      set_cookie = ctx.response_headers["set-cookie"].to_s
      token_name = ctx.context.auth_cookies[:session_token].name
      token = set_cookie.lines.filter_map do |line|
        cookie = bearer_session_cookie(line)
        next unless cookie && cookie[:name] == token_name
        next if cookie[:value].empty? || expired_bearer_cookie?(cookie)

        cookie[:value]
      end.first
      return unless token

      exposed = ctx.response_headers["access-control-expose-headers"].to_s.split(",").map(&:strip).reject(&:empty?)
      exposed << "set-auth-token"
      ctx.set_header("set-auth-token", token)
      ctx.set_header("access-control-expose-headers", exposed.uniq.join(", "))
      nil
    end
  end
end
