# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def figma(client_id:, client_secret:, scopes: ["current_user:read"], **options)
      Base.oauth_provider(
        id: "figma",
        name: "Figma",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://www.figma.com/oauth",
        token_endpoint: "https://api.figma.com/v1/oauth/token",
        user_info_endpoint: "https://api.figma.com/v1/me",
        scopes: scopes,
        pkce: true,
        require_code_verifier: true,
        token_authentication: :basic,
        profile_map: ->(profile) {
          {
            id: profile["id"],
            name: profile["handle"],
            email: profile["email"],
            image: profile["img_url"],
            emailVerified: false
          }
        },
        **options
      )
    end
  end
end
