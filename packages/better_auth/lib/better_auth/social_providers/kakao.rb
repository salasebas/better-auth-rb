# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def kakao(client_id:, client_secret: nil, scopes: ["account_email", "profile_image", "profile_nickname"], **options)
      Base.oauth_provider(
        id: "kakao",
        name: "Kakao",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://kauth.kakao.com/oauth/authorize",
        token_endpoint: "https://kauth.kakao.com/oauth/token",
        user_info_endpoint: "https://kapi.kakao.com/v2/user/me",
        scopes: scopes,
        profile_map: ->(profile) {
          account = profile["kakao_account"] || {}
          kakao_profile = account["profile"] || {}
          {
            id: profile["id"].to_s,
            name: kakao_profile["nickname"] || account["name"] || "",
            email: account["email"],
            image: kakao_profile["profile_image_url"] || kakao_profile["thumbnail_image_url"],
            emailVerified: !!account["is_email_valid"] && !!account["is_email_verified"]
          }
        },
        **options
      )
    end
  end
end
