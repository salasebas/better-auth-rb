# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def vk(client_id:, client_secret:, scopes: ["email", "phone"], **options)
      normalized = Base.normalize_options(options)
      provider = Base.oauth_provider(
        id: "vk",
        name: "VK",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://id.vk.com/authorize",
        token_endpoint: "https://id.vk.com/oauth2/auth",
        user_info_endpoint: "https://id.vk.com/oauth2/user_info",
        user_info_method: :post,
        user_info_body: {client_id: client_id},
        scopes: scopes,
        pkce: true,
        profile_map: ->(profile) {
          user = profile["user"] || profile
          {
            id: user["user_id"],
            name: [user["first_name"], user["last_name"]].compact.join(" "),
            email: user["email"],
            image: user["avatar"],
            emailVerified: false
          }
        },
        **options
      )
      provider[:get_user_info] = lambda do |tokens|
        custom = normalized[:get_user_info]
        next custom.call(tokens) if custom

        access_token = Base.access_token(tokens)
        next nil unless access_token

        profile = Base.post_json(
          "https://id.vk.com/oauth2/user_info",
          {access_token: access_token, client_id: client_id},
          "Content-Type" => "application/x-www-form-urlencoded"
        )
        next nil unless profile

        user_profile = profile["user"] || profile
        user_map = normalized[:map_profile_to_user]&.call(profile) || {}
        next nil if user_profile["email"].to_s.empty? && user_map[:email].to_s.empty? && user_map["email"].to_s.empty?

        user = {
          id: user_profile["user_id"],
          first_name: user_profile["first_name"],
          last_name: user_profile["last_name"],
          name: [user_profile["first_name"], user_profile["last_name"]].compact.join(" "),
          email: user_profile["email"],
          image: user_profile["avatar"],
          emailVerified: false,
          birthday: user_profile["birthday"],
          sex: user_profile["sex"]
        }.merge(user_map)
        {user: user, data: profile}
      end
      provider
    end
  end
end
