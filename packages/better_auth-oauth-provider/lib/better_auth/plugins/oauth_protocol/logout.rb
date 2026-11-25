# frozen_string_literal: true

require "jwt"
require "openssl"

module BetterAuth
  module Plugins
    module OAuthProtocol
      module_function

      def legacy_id_token_hs256_key(ctx, client_id)
        label = client_id.to_s.empty? ? "better-auth" : client_id.to_s
        OpenSSL::HMAC.hexdigest("SHA256", ctx.context.secret.to_s, "oidc.id_token.#{label}")
      end

      def verify_oauth_hs256_jwt(token, hs256_secret, issuer:)
        ::JWT.decode(token, hs256_secret.to_s, true, algorithm: "HS256", iss: issuer, verify_iss: true).first
      end
    end
  end
end
