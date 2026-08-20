# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def linkedin(client_id:, client_secret: nil, scopes: ["profile", "email", "openid"], **options)
      Base.oauth_provider(
        id: "linkedin",
        name: "Linkedin",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://www.linkedin.com/oauth/v2/authorization",
        token_endpoint: "https://www.linkedin.com/oauth/v2/accessToken",
        user_info_endpoint: "https://api.linkedin.com/v2/userinfo",
        scopes: scopes,
        profile_map: ->(profile) {
          {
            id: profile["sub"],
            name: profile["name"],
            email: profile["email"],
            image: profile["picture"],
            emailVerified: !!profile["email_verified"]
          }
        },
        **options
      )
    end
  end
end
