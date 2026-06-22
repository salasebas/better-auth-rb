# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def line(client_id:, client_secret:, scopes: ["openid", "profile", "email"], **options)
      normalized = Base.normalize_options(options)
      provider = Base.oauth_provider(
        id: "line",
        name: "LINE",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://access.line.me/oauth2/v2.1/authorize",
        token_endpoint: "https://api.line.me/oauth2/v2.1/token",
        user_info_endpoint: "https://api.line.me/oauth2/v2.1/userinfo",
        scopes: scopes,
        pkce: true,
        profile_map: ->(profile) {
          {
            id: profile["sub"] || profile["userId"],
            name: profile["name"] || profile["displayName"] || "",
            email: profile["email"],
            image: profile["picture"] || profile["pictureUrl"],
            emailVerified: false
          }
        },
        **options
      )
      provider[:verify_id_token] ||= lambda do |token, nonce = nil|
        return false if normalized[:disable_id_token_sign_in]

        profile = Base.post_form_json(
          normalized[:verify_id_token_endpoint] || "https://api.line.me/oauth2/v2.1/verify",
          {id_token: token, client_id: client_id, nonce: nonce}
        )
        next false unless profile
        next false unless profile["aud"] == client_id
        next false if profile["nonce"] && profile["nonce"] != nonce

        true
      end
      provider[:get_user_info] = lambda do |tokens|
        custom = normalized[:get_user_info]
        next custom.call(tokens) if custom

        profile = Base.id_token(tokens) ? Base.decode_jwt_payload(Base.id_token(tokens)) : {}
        profile = Base.fetch_user_info("https://api.line.me/oauth2/v2.1/userinfo", tokens) if profile.empty?
        next nil unless profile && !profile.empty?

        user = Base.apply_profile_mapping(
          {
            id: profile["sub"] || profile["userId"],
            name: profile["name"] || profile["displayName"] || "",
            email: profile["email"],
            image: profile["picture"] || profile["pictureUrl"],
            emailVerified: false
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
