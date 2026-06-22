# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def twitter(client_id:, client_secret:, scopes: ["users.read", "tweet.read", "offline.access", "users.email"], **options)
      normalized = Base.normalize_options(options)
      provider = Base.oauth_provider(
        id: "twitter",
        name: "Twitter",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://x.com/i/oauth2/authorize",
        token_endpoint: "https://api.x.com/2/oauth2/token",
        user_info_endpoint: "https://api.x.com/2/users/me?user.fields=profile_image_url,verified",
        scopes: scopes,
        pkce: true,
        token_authentication: :basic,
        profile_map: ->(profile) {
          data = profile["data"] || profile
          {
            id: data["id"],
            name: data["name"],
            email: data["email"] || data["username"],
            image: data["profile_image_url"],
            emailVerified: !!data["confirmed_email"]
          }
        },
        **options
      )
      provider[:get_user_info] = lambda do |tokens|
        custom = normalized[:get_user_info]
        next custom.call(tokens) if custom

        profile = Base.get_json(
          "https://api.x.com/2/users/me?user.fields=profile_image_url",
          "Authorization" => "Bearer #{Base.access_token(tokens)}"
        )
        next nil unless profile

        email_data = Base.get_json(
          "https://api.x.com/2/users/me?user.fields=confirmed_email",
          "Authorization" => "Bearer #{Base.access_token(tokens)}"
        )
        data = profile["data"] || profile
        confirmed_email = email_data&.dig("data", "confirmed_email")
        data["email"] = confirmed_email if confirmed_email
        data["confirmed_email"] = true if confirmed_email

        user = Base.apply_profile_mapping(
          {
            id: data["id"],
            name: data["name"],
            email: data["email"] || data["username"],
            image: data["profile_image_url"],
            emailVerified: !!data["confirmed_email"]
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
