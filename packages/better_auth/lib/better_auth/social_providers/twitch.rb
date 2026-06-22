# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def twitch(client_id:, client_secret:, scopes: ["user:read:email", "openid"], **options)
      normalized = Base.normalize_options(options)
      provider = Base.oauth_provider(
        id: "twitch",
        name: "Twitch",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://id.twitch.tv/oauth2/authorize",
        token_endpoint: "https://id.twitch.tv/oauth2/token",
        scopes: scopes,
        auth_params: {
          claims: JSON.generate({
            userinfo: {
              email: nil,
              email_verified: nil,
              preferred_username: nil,
              picture: nil
            }
          })
        },
        profile_map: ->(profile) {
          {
            id: profile["sub"],
            name: profile["preferred_username"],
            email: profile["email"],
            image: profile["picture"],
            emailVerified: !!profile["email_verified"]
          }
        },
        **options
      )
      provider[:get_user_info] = lambda do |tokens|
        custom = normalized[:get_user_info]
        next custom.call(tokens) if custom
        next nil unless Base.id_token(tokens)

        profile = Base.decode_jwt_payload(Base.id_token(tokens))
        next nil if profile.empty?

        user = Base.apply_profile_mapping(
          {
            id: profile["sub"],
            name: profile["preferred_username"],
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
