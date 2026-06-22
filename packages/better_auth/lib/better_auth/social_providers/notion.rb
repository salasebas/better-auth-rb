# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def notion(client_id:, client_secret:, scopes: [], **options)
      Base.oauth_provider(
        id: "notion",
        name: "Notion",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://api.notion.com/v1/oauth/authorize",
        token_endpoint: "https://api.notion.com/v1/oauth/token",
        user_info_endpoint: "https://api.notion.com/v1/users/me",
        scopes: scopes,
        auth_params: {owner: "user"},
        token_authentication: :basic,
        user_info_headers: {"Notion-Version" => "2022-06-28"},
        profile_map: ->(profile) {
          user = profile.dig("bot", "owner", "user") || profile
          {
            id: user["id"],
            name: user["name"] || "",
            email: user.dig("person", "email"),
            image: user["avatar_url"],
            emailVerified: false
          }
        },
        **options
      )
    end
  end
end
