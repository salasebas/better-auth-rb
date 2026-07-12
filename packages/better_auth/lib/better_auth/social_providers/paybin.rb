# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def paybin(client_id:, client_secret:, scopes: ["openid", "email", "profile"], **options)
      normalized = Base.normalize_options(options)
      issuer = (options[:issuer] || "https://idp.paybin.io").to_s.sub(%r{/+\z}, "")
      provider = Base.oauth_provider(
        id: "paybin",
        name: "Paybin",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "#{issuer}/oauth2/authorize",
        token_endpoint: "#{issuer}/oauth2/token",
        scopes: scopes,
        pkce: true,
        require_code_verifier: true,
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
      provider[:get_user_info] = lambda do |tokens|
        custom = normalized[:get_user_info]
        next custom.call(tokens) if custom
        next nil unless Base.id_token(tokens)

        profile = Base.decode_jwt_payload(Base.id_token(tokens))
        next nil if profile.empty?

        user = Base.apply_profile_mapping(
          {
            id: profile["sub"],
            name: profile["name"] || profile["preferred_username"] || "",
            email: profile["email"],
            image: profile["picture"],
            emailVerified: !!profile["email_verified"]
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
