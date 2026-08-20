# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def huggingface(client_id:, client_secret: nil, scopes: ["openid", "profile", "email"], **options)
      Base.oauth_provider(
        id: "huggingface",
        name: "Hugging Face",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://huggingface.co/oauth/authorize",
        token_endpoint: "https://huggingface.co/oauth/token",
        user_info_endpoint: "https://huggingface.co/oauth/userinfo",
        scopes: scopes,
        pkce: true,
        profile_map: ->(profile) {
          {
            id: profile["sub"],
            name: profile["name"] || profile["preferred_username"] || "",
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
