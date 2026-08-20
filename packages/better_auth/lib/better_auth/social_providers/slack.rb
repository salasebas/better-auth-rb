# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def slack(client_id:, client_secret: nil, scopes: ["openid", "profile", "email"], **options)
      Base.oauth_provider(
        id: "slack",
        name: "Slack",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://slack.com/openid/connect/authorize",
        token_endpoint: "https://slack.com/api/openid.connect.token",
        user_info_endpoint: "https://slack.com/api/openid.connect.userInfo",
        scopes: scopes,
        profile_map: ->(profile) {
          {
            id: profile["https://slack.com/user_id"] || profile["sub"],
            name: profile["name"] || "",
            email: profile["email"],
            image: profile["picture"] || profile["https://slack.com/user_image_512"],
            emailVerified: !!profile["email_verified"]
          }
        },
        **options
      )
    end
  end
end
