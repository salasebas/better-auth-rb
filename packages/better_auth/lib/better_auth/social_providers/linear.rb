# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def linear(client_id:, client_secret:, scopes: ["read"], **options)
      provider = Base.oauth_provider(
        id: "linear",
        name: "Linear",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://linear.app/oauth/authorize",
        token_endpoint: "https://api.linear.app/oauth/token",
        scopes: scopes,
        profile_map: ->(profile) {
          viewer = profile.dig("data", "viewer") || {}
          {
            id: viewer["id"],
            name: viewer["name"],
            email: viewer["email"],
            image: viewer["avatarUrl"],
            emailVerified: false
          }
        },
        **options
      )
      provider[:get_user_info] = lambda do |tokens|
        custom = Base.option(provider[:options], :get_user_info)
        profile = custom ? custom.call(tokens) : Base.post_json(
          "https://api.linear.app/graphql",
          {query: "{ viewer { id name email avatarUrl active createdAt updatedAt } }"},
          "Authorization" => "Bearer #{Base.access_token(tokens)}"
        )
        return profile if Base.provider_user_info?(profile)
        return nil unless profile

        mapped = provider[:options][:map_profile_to_user]&.call(profile) || {}
        viewer = profile.dig("data", "viewer") || {}
        {user: {id: viewer["id"], name: viewer["name"], email: viewer["email"], image: viewer["avatarUrl"], emailVerified: false}.merge(mapped), data: profile}
      end
      provider
    end
  end
end
