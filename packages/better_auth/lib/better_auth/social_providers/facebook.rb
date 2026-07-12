# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def facebook(client_id:, client_secret:, scopes: ["email", "public_profile"], **options)
      normalized = Base.normalize_options(options)
      fields = Array(options[:fields] || %w[id name email picture email_verified]).join(",")
      provider = Base.oauth_provider(
        id: "facebook",
        name: "Facebook",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://www.facebook.com/v24.0/dialog/oauth",
        token_endpoint: "https://graph.facebook.com/v24.0/oauth/access_token",
        user_info_endpoint: "https://graph.facebook.com/me?fields=#{URI.encode_www_form_component(fields)}",
        scopes: scopes,
        auth_params: ->(_data, opts) { {config_id: opts[:config_id] || opts[:configId]} },
        profile_map: ->(profile) {
          picture = profile.dig("picture", "data", "url") || profile["picture"]
          {
            id: profile["id"] || profile["sub"],
            name: profile["name"],
            email: profile["email"],
            image: picture,
            emailVerified: !!profile["email_verified"]
          }
        },
        **options
      )
      provider[:verify_id_token] ||= lambda do |token, nonce = nil|
        return false if normalized[:disable_id_token_sign_in]
        return true unless token.to_s.split(".").length == 3

        profile = Base.verify_jwt_with_jwks(
          token,
          jwks: normalized[:jwks],
          jwks_endpoint: normalized[:jwks_endpoint] || "https://limited.facebook.com/.well-known/oauth/openid/jwks/",
          algorithms: ["RS256"],
          issuers: "https://www.facebook.com",
          audience: Array(client_id),
          nonce: nonce
        )
        !!profile
      end
      provider[:get_user_info] = lambda do |tokens|
        custom = normalized[:get_user_info]
        next custom.call(tokens) if custom

        token = Base.id_token(tokens)
        if token && token.split(".").length == 3
          profile = Base.decode_jwt_payload(token)
          user = Base.apply_profile_mapping(
            {
              id: profile["sub"],
              name: profile["name"],
              email: profile["email"],
              image: profile["picture"],
              emailVerified: false
            },
            profile.merge("email_verified" => false),
            normalized
          )
          next({user: user, data: profile})
        end

        profile = Base.fetch_user_info("https://graph.facebook.com/me?fields=#{URI.encode_www_form_component(fields)}", tokens)
        next nil unless profile

        picture = profile.dig("picture", "data", "url") || profile["picture"]
        user = Base.apply_profile_mapping(
          {
            id: profile["id"] || profile["sub"],
            name: profile["name"],
            email: profile["email"],
            image: picture,
            emailVerified: !!profile["email_verified"]
          },
          profile,
          normalized
        )
        {user: user, data: profile}
      end
      provider
    end
  end
end
