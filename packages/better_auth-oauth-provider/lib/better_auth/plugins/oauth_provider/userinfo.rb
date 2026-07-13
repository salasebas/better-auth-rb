# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def oauth_userinfo_endpoint(config)
      Endpoint.new(path: "/oauth2/userinfo", method: ["GET", "POST"]) do |ctx|
        ctx.json(OAuthProtocol.userinfo(config[:store], ctx.headers["authorization"], additional_claim: config[:custom_user_info_claims] || config[:additional_claim], prefix: config[:prefix], jwt_secret: ctx.context.secret, ctx: ctx, issuer: OAuthProvider.validate_issuer_url(OAuthProtocol.issuer(ctx))))
      end
    end
  end
end
