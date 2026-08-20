# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def polar(client_id:, client_secret: nil, scopes: ["openid", "profile", "email"], **options)
      Base.oauth_provider(
        id: "polar",
        name: "Polar",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://polar.sh/oauth2/authorize",
        token_endpoint: "https://api.polar.sh/v1/oauth2/token",
        user_info_endpoint: "https://api.polar.sh/v1/oauth2/userinfo",
        scopes: scopes,
        pkce: true,
        profile_map: ->(profile) {
          {
            id: profile["id"],
            name: profile["public_name"] || profile["username"] || "",
            email: profile["email"],
            image: profile["avatar_url"],
            emailVerified: !!profile["email_verified"]
          }
        },
        **options
      )
    end
  end
end
