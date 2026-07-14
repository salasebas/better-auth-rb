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
      issuer = sandbox ? "https://www.sandbox.paypal.com" : "https://www.paypal.com"
      jwks_endpoint = normalized[:jwks_endpoint] || (sandbox ? "https://api.sandbox.paypal.com/v1/oauth2/certs" : "https://api.paypal.com/v1/oauth2/certs")
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
      provider[:verify_id_token] = lambda do |token, nonce = nil|
        return false if normalized[:disable_id_token_sign_in]

        custom = normalized[:verify_id_token]
        next custom.call(token, nonce) if custom

        begin
          encoded_header, _encoded_payload, signature = token.to_s.split(".", 3)
          next false if encoded_header.to_s.empty? || signature.to_s.empty?

          header = JSON.parse(Base64.urlsafe_decode64(Base.padded_base64(encoded_header)))
          algorithm = header["alg"]
          profile = case algorithm
          when "RS256"
            Base.verify_jwt_with_jwks(
              token,
              jwks: normalized[:jwks],
              jwks_endpoint: jwks_endpoint,
              algorithms: ["RS256"],
              issuers: issuer,
              audience: Array(client_id),
              nonce: nonce,
              max_age: 3600
            )
          when "HS256"
            next false if client_secret.to_s.empty?

            claims, = JWT.decode(token.to_s, client_secret, true, {
              algorithm: "HS256",
              aud: Array(client_id),
              verify_aud: true,
              iss: issuer,
              verify_iss: true
            })
            next false if nonce && claims["nonce"] != nonce

            claims
          else
            next false
          end

          issued_at = Integer(profile.fetch("iat"))
          token_age = Time.now.to_i - issued_at
          next false if token_age.negative? || token_age > 3600

          !!profile.fetch("sub", nil)
        rescue
          false
        end
      end
      provider[:get_user_info] = lambda do |tokens|
        custom = normalized[:get_user_info]
        next custom.call(tokens) if custom

        begin
          access_token = Base.access_token(tokens)
          next nil if access_token.to_s.empty?

          profile = Base.fetch_user_info("#{api_host}/v1/identity/oauth2/userinfo?schema=paypalv1.1", tokens)
          next nil unless profile.is_a?(Hash)
          next nil if profile["user_id"].to_s.empty?

          id_token = Base.id_token(tokens)
          if id_token
            id_token_subject = Base.decode_jwt_payload(id_token)["sub"]
            profile_subject = profile["sub"] || profile["user_id"]
            next nil if id_token_subject.to_s.empty? || profile_subject.to_s.empty? || id_token_subject != profile_subject
          end

          user = Base.apply_profile_mapping(
            {
              id: profile["user_id"],
              name: profile["name"],
              email: profile["email"],
              image: profile["picture"],
              emailVerified: !!profile["email_verified"]
            },
            profile,
            normalized
          )
          {user: user, data: profile}
        rescue
          nil
        end
      end
      provider
    end
  end
end
