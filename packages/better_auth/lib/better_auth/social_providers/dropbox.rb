# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def dropbox(client_id:, client_secret: nil, scopes: ["account_info.read"], **options)
      Base.oauth_provider(
        id: "dropbox",
        name: "Dropbox",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://www.dropbox.com/oauth2/authorize",
        token_endpoint: "https://api.dropboxapi.com/oauth2/token",
        user_info_endpoint: "https://api.dropboxapi.com/2/users/get_current_account",
        user_info_method: :post,
        scopes: scopes,
        pkce: true,
        auth_params: ->(_data, opts) { {token_access_type: opts[:access_type] || opts[:accessType]} },
        profile_map: ->(profile) {
          {
            id: profile["account_id"],
            name: profile.dig("name", "display_name"),
            email: profile["email"],
            image: profile["profile_photo_url"],
            emailVerified: !!profile["email_verified"]
          }
        },
        **options
      )
    end
  end
end
