# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def cognito(client_id:, client_secret: nil, scopes: ["openid", "profile", "email"], **options)
      normalized = Base.normalize_options(options)
      domain = normalized[:domain]
      region = normalized[:region]
      user_pool_id = normalized[:user_pool_id]
      raise Error, "DOMAIN_AND_REGION_REQUIRED" if domain.to_s.empty? || region.to_s.empty? || user_pool_id.to_s.empty?

      if normalized[:require_client_secret] && client_secret.to_s.empty?
        raise Error, "CLIENT_SECRET_REQUIRED"
      end

      clean_domain = domain.to_s.sub(%r{\Ahttps?://}, "").sub(%r{/+\z}, "")
      provider = Base.oauth_provider(
        id: "cognito",
        name: "Cognito",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://#{clean_domain}/oauth2/authorize",
        token_endpoint: "https://#{clean_domain}/oauth2/token",
        user_info_endpoint: "https://#{clean_domain}/oauth2/userinfo",
        scopes: scopes,
        pkce: true,
        profile_map: ->(profile) {
          {
            id: profile["sub"],
            name: profile["name"] || profile["given_name"] || profile["username"] || "",
            email: profile["email"],
            image: profile["picture"],
            emailVerified: !!profile["email_verified"]
          }
        },
        **options
      )
      create_authorization_url = provider.fetch(:create_authorization_url)
      provider[:create_authorization_url] = lambda do |data|
        create_authorization_url.call(data).sub(/scope=([^&]+)/) { "scope=#{$1.gsub("+", "%20")}" }
      end
      provider[:verify_id_token] ||= lambda do |token, nonce = nil|
        return false if normalized[:disable_id_token_sign_in]

        profile = Base.verify_jwt_with_jwks(
          token,
          jwks: normalized[:jwks],
          jwks_endpoint: normalized[:jwks_endpoint] || "https://cognito-idp.#{region}.amazonaws.com/#{user_pool_id}/.well-known/jwks.json",
          algorithms: ["RS256"],
          issuers: "https://cognito-idp.#{region}.amazonaws.com/#{user_pool_id}",
          audience: Array(client_id),
          nonce: nonce,
          max_age: 3600
        )
        !!profile&.fetch("sub", nil)
      end
      provider[:get_user_info] = lambda do |tokens|
        custom = normalized[:get_user_info]
        next custom.call(tokens) if custom

        if Base.id_token(tokens)
          profile = Base.decode_jwt_payload(Base.id_token(tokens))
          unless profile.empty?
            name = profile["name"] || profile["given_name"] || profile["username"] || ""
            enriched = profile.merge("name" => name)
            user = Base.apply_profile_mapping(
              {
                id: profile["sub"],
                name: name,
                email: profile["email"],
                image: profile["picture"],
                emailVerified: !!profile["email_verified"]
              },
              enriched,
              normalized
            )
            next({user: user, data: enriched})
          end
        end

        profile = Base.fetch_user_info("https://#{clean_domain}/oauth2/userinfo", tokens)
        next nil unless profile

        user = Base.apply_profile_mapping(
          {
            id: profile["sub"],
            name: profile["name"] || profile["given_name"] || profile["username"] || "",
            email: profile["email"],
            image: profile["picture"],
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
