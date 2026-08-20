# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def zoom(client_id:, client_secret: nil, scopes: [], **options)
      Base.oauth_provider(
        id: "zoom",
        name: "Zoom",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://zoom.us/oauth/authorize",
        token_endpoint: "https://zoom.us/oauth/token",
        user_info_endpoint: "https://api.zoom.us/v2/users/me",
        scopes: scopes,
        pkce: options.fetch(:pkce, true),
        profile_map: ->(profile) {
          {
            id: profile["id"],
            name: profile["display_name"],
            email: profile["email"],
            image: profile["pic_url"],
            emailVerified: !!profile["verified"]
          }
        },
        **options
      )
    end
  end
end
