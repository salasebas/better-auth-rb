# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def roblox(client_id:, client_secret: nil, scopes: ["openid", "profile"], **options)
      Base.oauth_provider(
        id: "roblox",
        name: "Roblox",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://apis.roblox.com/oauth/v1/authorize",
        token_endpoint: "https://apis.roblox.com/oauth/v1/token",
        user_info_endpoint: "https://apis.roblox.com/oauth/v1/userinfo",
        scopes: scopes,
        auth_params: ->(_data, opts) { {prompt: opts[:prompt] || "select_account consent"} },
        profile_map: ->(profile) {
          {
            id: profile["sub"],
            name: profile["nickname"] || profile["preferred_username"] || "",
            email: profile["preferred_username"],
            image: profile["picture"],
            emailVerified: false
          }
        },
        **options
      )
    end
  end
end
