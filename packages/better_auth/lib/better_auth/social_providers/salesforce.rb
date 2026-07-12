# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def salesforce(client_id:, client_secret:, scopes: ["openid", "email", "profile"], **options)
      host = if options[:loginUrl] || options[:login_url]
        "https://#{options[:loginUrl] || options[:login_url]}"
      elsif options[:environment].to_s == "sandbox"
        "https://test.salesforce.com"
      else
        "https://login.salesforce.com"
      end
      Base.oauth_provider(
        id: "salesforce",
        name: "Salesforce",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "#{host}/services/oauth2/authorize",
        token_endpoint: "#{host}/services/oauth2/token",
        user_info_endpoint: "#{host}/services/oauth2/userinfo",
        scopes: scopes,
        pkce: true,
        require_code_verifier: true,
        profile_map: ->(profile) {
          {
            id: profile["user_id"],
            name: profile["name"],
            email: profile["email"],
            image: profile.dig("photos", "picture") || profile.dig("photos", "thumbnail"),
            emailVerified: !!profile["email_verified"]
          }
        },
        **options
      )
    end
  end
end
