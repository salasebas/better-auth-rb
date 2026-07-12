# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def atlassian(client_id:, client_secret:, scopes: ["read:jira-user", "offline_access"], **options)
      Base.oauth_provider(
        id: "atlassian",
        name: "Atlassian",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://auth.atlassian.com/authorize",
        token_endpoint: "https://auth.atlassian.com/oauth/token",
        user_info_endpoint: "https://api.atlassian.com/me",
        scopes: scopes,
        pkce: true,
        require_code_verifier: true,
        auth_params: {audience: "api.atlassian.com"},
        profile_map: ->(profile) {
          {
            id: profile["account_id"],
            name: profile["name"],
            email: profile["email"],
            image: profile["picture"],
            emailVerified: false
          }
        },
        **options
      )
    end
  end
end
