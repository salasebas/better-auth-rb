# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def railway(client_id:, client_secret: nil, scopes: ["openid", "email", "profile"], **options)
      primary_client_id = Base.primary_client_id(client_id)
      credentials = Base64.strict_encode64("#{primary_client_id}:#{client_secret}")
      token_endpoint = options[:token_endpoint] || options[:tokenEndpoint] || "https://backboard.railway.com/oauth/token"
      provider = Base.oauth_provider(
        id: "railway",
        name: "Railway",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://backboard.railway.com/oauth/auth",
        token_endpoint: "https://backboard.railway.com/oauth/token",
        user_info_endpoint: "https://backboard.railway.com/oauth/me",
        scopes: scopes,
        pkce: true,
        profile_map: ->(profile) {
          {
            id: profile["sub"],
            name: profile["name"],
            email: profile["email"],
            image: profile["picture"],
            emailVerified: false
          }
        },
        **options
      )
      provider[:validate_authorization_code] = lambda do |data|
        Base.post_form_json(token_endpoint, {
          code: data[:code],
          code_verifier: data[:code_verifier] || data[:codeVerifier],
          grant_type: "authorization_code",
          redirect_uri: options[:redirect_uri] || options[:redirectURI] || data[:redirect_uri] || data[:redirectURI]
        }, {"Authorization" => "Basic #{credentials}"})
      end
      provider[:refresh_access_token] = options[:refresh_access_token] || options[:refreshAccessToken] || lambda do |refresh_token|
        Base.normalize_tokens(Base.post_form_json(token_endpoint, {
          grant_type: "refresh_token",
          refresh_token: refresh_token
        }, {"Authorization" => "Basic #{credentials}"}))
      end
      provider
    end
  end
end
