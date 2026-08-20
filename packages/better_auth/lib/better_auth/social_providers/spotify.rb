# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def spotify(client_id:, client_secret: nil, scopes: ["user-read-email"], **options)
      Base.oauth_provider(
        id: "spotify",
        name: "Spotify",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://accounts.spotify.com/authorize",
        token_endpoint: "https://accounts.spotify.com/api/token",
        user_info_endpoint: "https://api.spotify.com/v1/me",
        scopes: scopes,
        pkce: true,
        profile_map: ->(profile) {
          {
            id: profile["id"],
            name: profile["display_name"],
            email: profile["email"],
            image: Array(profile["images"]).first&.fetch("url", nil),
            emailVerified: false
          }
        },
        **options
      )
    end
  end
end
