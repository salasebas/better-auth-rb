# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def reddit(client_id:, client_secret:, scopes: ["identity"], **options)
      normalized = Base.normalize_options(options)
      token_endpoint = normalized[:token_endpoint] || "https://www.reddit.com/api/v1/access_token"
      provider = Base.oauth_provider(
        id: "reddit",
        name: "Reddit",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://www.reddit.com/api/v1/authorize",
        token_endpoint: token_endpoint,
        user_info_endpoint: "https://oauth.reddit.com/api/v1/me",
        user_info_headers: {"User-Agent" => "better-auth"},
        scopes: scopes,
        auth_params: ->(_data, opts) { {duration: opts[:duration]} },
        token_authentication: :basic,
        profile_map: ->(profile) {
          {
            id: profile["id"],
            name: profile["name"],
            email: profile["oauth_client_id"],
            image: profile["icon_img"].to_s.split("?").first,
            emailVerified: !!profile["has_verified_email"]
          }
        },
        **options
      )
      provider[:validate_authorization_code] = lambda do |data|
        Base.post_token_form(
          token_endpoint,
          {
            code: data[:code] || data["code"],
            grant_type: "authorization_code",
            redirect_uri: data[:redirect_uri] || data[:redirectURI] || data["redirect_uri"] || data["redirectURI"]
          },
          client_id: Base.primary_client_id(client_id),
          client_secret: client_secret,
          authentication: :basic,
          headers: {
            "accept" => "text/plain",
            "user-agent" => "better-auth"
          }
        )
      end
      provider
    end
  end
end
