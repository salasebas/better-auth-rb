# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def google_hosted_domain_allowed?(configured_hosted_domain, token_hosted_domain)
      return true if configured_hosted_domain.nil? || configured_hosted_domain.to_s.empty?
      return false unless token_hosted_domain.is_a?(String) && !token_hosted_domain.strip.empty?
      return true if configured_hosted_domain == "*"

      token_hosted_domain == configured_hosted_domain
    end

    def google(client_id:, client_secret:, scopes: ["openid", "email", "profile"], **options)
      normalized = Base.normalize_options(options)
      primary_client_id = Base.primary_client_id(client_id)
      {
        id: "google",
        name: "Google",
        client_id: client_id,
        client_secret: client_secret,
        options: normalized,
        create_authorization_url: lambda do |data|
          verifier = data[:code_verifier] || data[:codeVerifier]
          raise Error, "codeVerifier is required for Google" if verifier.to_s.empty?

          Base.authorization_url(options[:authorization_endpoint] || "https://accounts.google.com/o/oauth2/v2/auth", {
            client_id: primary_client_id,
            redirect_uri: data[:redirect_uri] || data[:redirectURI],
            response_type: "code",
            scope: Base.selected_scopes(scopes, normalized, data),
            state: data[:state],
            code_challenge: verifier && Base.pkce_challenge(verifier),
            code_challenge_method: verifier && "S256",
            login_hint: data[:loginHint] || data[:login_hint],
            prompt: options[:prompt],
            access_type: options[:access_type] || options[:accessType] || "offline",
            display: data[:display] || options[:display],
            hd: options[:hd],
            include_granted_scopes: "true"
          })
        end,
        validate_authorization_code: lambda do |data|
          Base.post_form("https://oauth2.googleapis.com/token", {
            client_id: primary_client_id,
            client_secret: client_secret,
            code: data[:code],
            code_verifier: data[:code_verifier] || data[:codeVerifier],
            grant_type: "authorization_code",
            redirect_uri: data[:redirect_uri] || data[:redirectURI]
          })
        end,
        verify_id_token: normalized[:verify_id_token] || lambda do |token, nonce = nil|
          return false if normalized[:disable_id_token_sign_in]

          audiences = Array(client_id)
          return false if audiences.empty?

          profile = Base.verify_jwt_with_jwks(
            token,
            jwks: normalized[:jwks],
            jwks_endpoint: normalized[:jwks_endpoint] || "https://www.googleapis.com/oauth2/v3/certs",
            algorithms: ["RS256"],
            issuers: ["https://accounts.google.com", "accounts.google.com"],
            audience: audiences,
            nonce: nonce
          )
          !!profile&.fetch("sub", nil) && google_hosted_domain_allowed?(normalized[:hd], profile["hd"])
        end,
        get_user_info: lambda do |tokens|
          custom = normalized[:get_user_info]
          next custom.call(tokens) if custom
          next nil unless Base.id_token(tokens)

          profile = Base.decode_jwt_payload(Base.id_token(tokens))
          next nil unless google_hosted_domain_allowed?(normalized[:hd], profile["hd"])

          user = Base.apply_profile_mapping(
            {
              id: profile["sub"],
              email: profile["email"],
              name: profile["name"],
              image: profile["picture"],
              emailVerified: !!profile["email_verified"]
            },
            profile,
            normalized
          )
          {
            user: user,
            data: profile
          }
        end,
        refresh_access_token: options[:refresh_access_token] || options[:refreshAccessToken] || lambda do |refresh_token|
          Base.refresh_access_token("https://oauth2.googleapis.com/token", refresh_token, client_id: primary_client_id, client_secret: client_secret)
        end
      }
    end
  end
end
