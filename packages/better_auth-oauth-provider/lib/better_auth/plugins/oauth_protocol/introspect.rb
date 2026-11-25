# frozen_string_literal: true

require "jwt"

module BetterAuth
  module Plugins
    module OAuthProtocol
      module_function

      def token_record(store, token, prefix: {})
        token_value = strip_prefix(token, prefix, :access_token)
        data = token_value ? store[:tokens][token_value] : nil
        return nil unless data
        return nil if data["revoked"]
        return nil if data["expiresAt"] && data["expiresAt"] <= Time.now

        data
      end

      def find_token_by_hint(store, token, hint, prefix: {}, format_refresh_token: nil)
        access = -> { (value = strip_prefix(token, prefix, :access_token)) && store[:tokens][value] }
        refresh = lambda {
          value = decode_refresh_token(token, prefix: prefix, format_refresh_token: format_refresh_token)
          value && store[:refresh_tokens][value]
        }

        case hint.to_s
        when "access_token"
          access.call
        when "refresh_token"
          refresh.call
        else
          access.call || refresh.call
        end
      end

      def verify_oauth_jwt(ctx, token, issuer:, hs256_secret:)
        payload = ::JWT.decode(token.to_s, nil, false).first
        audience = payload["aud"]
        config = oauth_jwt_config(ctx, issuer: issuer, audience: audience.is_a?(Array) ? audience.first : audience)
        verified = BetterAuth::Plugins.verify_jwt_token(ctx, token, config) if config
        return verified if verified

        ::JWT.decode(token, hs256_secret.to_s, true, algorithm: "HS256").first
      end
    end
  end
end
