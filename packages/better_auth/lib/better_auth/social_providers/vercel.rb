# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def vercel(client_id:, client_secret: nil, scopes: [], **options)
      provider = Base.oauth_provider(
        id: "vercel",
        name: "Vercel",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://vercel.com/oauth/authorize",
        token_endpoint: "https://api.vercel.com/login/oauth/token",
        user_info_endpoint: "https://api.vercel.com/login/oauth/userinfo",
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
      provider[:create_authorization_url] = lambda do |data|
        verifier = data[:code_verifier] || data[:codeVerifier]
        raise Error, "codeVerifier is required for Vercel" if verifier.to_s.empty?

        selected_scopes = Base.selected_scopes(scopes, Base.normalize_options(options), data)
        Base.authorization_url(options[:authorization_endpoint] || "https://vercel.com/oauth/authorize", {
          client_id: Base.primary_client_id(client_id),
          redirect_uri: options[:redirect_uri] || options[:redirectURI] || data[:redirect_uri] || data[:redirectURI],
          response_type: "code",
          scope: selected_scopes.empty? ? nil : selected_scopes,
          state: data[:state],
          code_challenge: Base.pkce_challenge(verifier),
          code_challenge_method: "S256"
        })
      end
      provider
    end
  end
end
