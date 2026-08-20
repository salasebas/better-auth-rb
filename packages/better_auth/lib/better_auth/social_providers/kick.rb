# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def kick(client_id:, client_secret: nil, scopes: ["user:read"], **options)
      Base.oauth_provider(
        id: "kick",
        name: "Kick",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://id.kick.com/oauth/authorize",
        token_endpoint: "https://id.kick.com/oauth/token",
        user_info_endpoint: "https://api.kick.com/public/v1/users",
        scopes: scopes,
        pkce: true,
        profile_map: ->(profile) {
          user = Array(profile["data"]).first || profile
          {
            id: user["user_id"],
            name: user["name"],
            email: user["email"],
            image: user["profile_picture"],
            emailVerified: false
          }
        },
        **options
      )
    end
  end
end
