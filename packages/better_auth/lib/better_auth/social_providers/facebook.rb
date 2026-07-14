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
      verify_access_token = lambda do |access_token|
        primary_client_id = Base.primary_client_id(client_id)
        next nil if access_token.to_s.empty? || client_secret.to_s.empty?

        response = Base.get_json(Base.authorization_url("https://graph.facebook.com/debug_token", {
          input_token: access_token,
          access_token: "#{primary_client_id}|#{client_secret}"
        }))
        data = response.is_a?(Hash) ? response["data"] : nil
        next nil unless data.is_a?(Hash)
        next nil unless data["is_valid"] == true
        next nil unless Array(client_id).map(&:to_s).include?(data["app_id"].to_s)
        next nil if data["app_id"].to_s.empty? || data["user_id"].to_s.empty?

        data["user_id"]
      rescue
        nil
      end
      provider[:verify_id_token] = lambda do |token, nonce = nil|
        return false if normalized[:disable_id_token_sign_in]

        custom = normalized[:verify_id_token]
        next custom.call(token, nonce) if custom

        begin
          unless token.to_s.split(".").length == 3
            next !!verify_access_token.call(token)
          end

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
        rescue
          false
        end
      end
      provider[:get_user_info] = lambda do |tokens|
        custom = normalized[:get_user_info]
        next custom.call(tokens) if custom

        begin
          token = Base.id_token(tokens)
          if token && token.split(".").length == 3
            profile = Base.decode_jwt_payload(token)
            next nil if profile["sub"].to_s.empty?

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

          access_token = Base.access_token(tokens)
          next nil if access_token.to_s.empty?

          token_user_id = verify_access_token.call(access_token)
          next nil unless token_user_id

          profile = Base.fetch_user_info("https://graph.facebook.com/me?fields=#{URI.encode_www_form_component(fields)}", tokens)
          next nil unless profile.is_a?(Hash)
          next nil unless profile["id"] == token_user_id

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
        rescue
          nil
        end
      end
      provider
    end
  end
end
