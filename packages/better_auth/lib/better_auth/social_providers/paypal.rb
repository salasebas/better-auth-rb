# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def paypal(client_id:, client_secret:, scopes: [], **options)
      normalized = Base.normalize_options(options)
      sandbox = (options[:environment] || "sandbox").to_s == "sandbox"
      auth_host = sandbox ? "https://www.sandbox.paypal.com" : "https://www.paypal.com"
      api_host = sandbox ? "https://api-m.sandbox.paypal.com" : "https://api-m.paypal.com"
      token_endpoint = normalized[:token_endpoint] || "#{api_host}/v1/oauth2/token"
      provider = Base.oauth_provider(
        id: "paypal",
        name: "PayPal",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "#{auth_host}/signin/authorize",
        token_endpoint: token_endpoint,
        user_info_endpoint: "#{api_host}/v1/identity/oauth2/userinfo?schema=paypalv1.1",
        scopes: scopes,
        pkce: true,
        token_authentication: :basic,
        profile_map: ->(profile) {
          {
            id: profile["user_id"],
            name: profile["name"],
            email: profile["email"],
            image: profile["picture"],
            emailVerified: !!profile["email_verified"]
          }
        },
        **options
      )
      provider[:validate_authorization_code] = lambda do |data|
        Base.normalize_tokens(Base.post_token_form(
          token_endpoint,
          {
            code: data[:code] || data["code"],
            grant_type: "authorization_code",
            redirect_uri: data[:redirect_uri] || data[:redirectURI] || data["redirect_uri"] || data["redirectURI"]
          },
          client_id: Base.primary_client_id(client_id),
          client_secret: client_secret,
          authentication: :basic,
          headers: {"Accept-Language" => "en_US"}
        ))
      end
      provider[:refresh_access_token] = lambda do |refresh_token|
        Base.normalize_tokens(Base.post_token_form(
          token_endpoint,
          {
            grant_type: "refresh_token",
            refresh_token: refresh_token
          },
          client_id: Base.primary_client_id(client_id),
          client_secret: client_secret,
          authentication: :basic,
          headers: {"Accept-Language" => "en_US"}
        ))
      end
      provider[:verify_id_token] ||= lambda do |token, _nonce = nil|
        return false if normalized[:disable_id_token_sign_in]

        profile = Base.decode_jwt_payload(token)
        !!profile["sub"]
      end
      provider
    end
  end
end
