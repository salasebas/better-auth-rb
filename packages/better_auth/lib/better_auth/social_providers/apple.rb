# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def apple(client_id:, client_secret:, scopes: ["email", "name"], **options)
      normalized = Base.normalize_options(options)
      primary_client_id = Base.primary_client_id(client_id)
      {
        id: "apple",
        name: "Apple",
        client_id: client_id,
        client_secret: client_secret,
        create_authorization_url: lambda do |data|
          Base.authorization_url(options[:authorization_endpoint] || "https://appleid.apple.com/auth/authorize", {
            client_id: primary_client_id,
            redirect_uri: data[:redirect_uri] || data[:redirectURI],
            response_type: "code id_token",
            response_mode: options[:response_mode] || options[:responseMode] || "form_post",
            scope: Base.selected_scopes(scopes, normalized, data),
            state: data[:state]
          })
        end,
        validate_authorization_code: lambda do |data|
          Base.post_form("https://appleid.apple.com/auth/token", {
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

          audiences = Array(normalized[:audience] || normalized[:app_bundle_identifier] || normalized[:appBundleIdentifier] || client_id)
          return false if audiences.empty?

          profile = Base.verify_jwt_with_jwks(
            token,
            jwks: normalized[:jwks],
            jwks_endpoint: normalized[:jwks_endpoint] || "https://appleid.apple.com/auth/keys",
            algorithms: ["RS256"],
            issuers: "https://appleid.apple.com",
            audience: audiences,
            nonce: nil
          )
          if nonce
            token_nonce = profile&.fetch("nonce", nil)
            expected_nonces = [nonce, OpenSSL::Digest::SHA256.hexdigest(nonce.to_s)]
            return false unless token_nonce.is_a?(String) && expected_nonces.include?(token_nonce)
          end
          !!profile&.fetch("sub", nil)
        end,
        get_user_info: lambda do |tokens|
          custom = normalized[:get_user_info]
          next custom.call(tokens) if custom

          profile = Base.decode_jwt_payload(Base.id_token(tokens))
          apple_user = tokens[:user] || tokens["user"] || {}
          name = apple_user.dig(:name, :firstName) ||
            apple_user.dig(:name, :first_name) ||
            apple_user.dig("name", "firstName") ||
            apple_user.dig("name", "first_name")
          last_name = apple_user.dig(:name, :lastName) ||
            apple_user.dig(:name, :last_name) ||
            apple_user.dig("name", "lastName") ||
            apple_user.dig("name", "last_name")
          full_name = [name, last_name].compact.join(" ").strip
          full_name = profile["name"] || "" if full_name.empty?

          user = Base.apply_profile_mapping(
            {
              id: profile["sub"],
              email: profile["email"],
              name: full_name,
              image: profile["picture"],
              emailVerified: profile["email_verified"] == true || profile["email_verified"] == "true"
            },
            profile.merge("name" => full_name),
            normalized
          )
          {
            user: user,
            data: profile.merge("name" => full_name)
          }
        end,
        refresh_access_token: options[:refresh_access_token] || options[:refreshAccessToken] || lambda do |refresh_token|
          Base.refresh_access_token("https://appleid.apple.com/auth/token", refresh_token, client_id: primary_client_id, client_secret: client_secret)
        end
      }
    end
  end
end
