# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    MICROSOFT_CONSUMER_TENANT_ID = "9188040d-6c67-4c5b-b112-36a304b66dad"
    private_constant :MICROSOFT_CONSUMER_TENANT_ID

    module_function

    def microsoft_entra_id(client_id:, client_secret:, tenant_id: "common", scopes: ["openid", "profile", "email", "User.Read", "offline_access"], **options)
      normalized = Base.normalize_options(options)
      microsoft_provider(
        provider_id: "microsoft-entra-id",
        provider_name: "Microsoft Entra ID",
        client_id: client_id,
        client_secret: client_secret,
        tenant_id: normalized[:tenant_id] || tenant_id,
        scopes: scopes,
        **options
      )
    end

    def microsoft(client_id:, client_secret: nil, tenant_id: "common", scopes: ["openid", "profile", "email", "User.Read", "offline_access"], **options)
      normalized = Base.normalize_options(options)
      microsoft_provider(
        provider_id: "microsoft",
        provider_name: "Microsoft EntraID",
        client_id: client_id,
        client_secret: client_secret,
        tenant_id: normalized[:tenant_id] || tenant_id,
        scopes: scopes,
        **options
      )
    end

    def microsoft_provider(provider_id:, provider_name:, client_id:, client_secret:, tenant_id:, scopes:, **options)
      authority = options[:authority] || "https://login.microsoftonline.com"
      base = "#{authority.to_s.sub(%r{/+\z}, "")}/#{tenant_id}/oauth2/v2.0"
      normalized = Base.normalize_options(options)
      primary_client_id = Base.primary_client_id(client_id)
      {
        id: provider_id,
        name: provider_name,
        client_id: client_id,
        client_secret: client_secret,
        create_authorization_url: lambda do |data|
          verifier = data[:code_verifier] || data[:codeVerifier]
          Base.authorization_url(options[:authorization_endpoint] || "#{base}/authorize", {
            client_id: primary_client_id,
            redirect_uri: data[:redirect_uri] || data[:redirectURI],
            response_type: "code",
            scope: Base.selected_scopes(scopes, normalized, data),
            state: data[:state],
            code_challenge: verifier && Base.pkce_challenge(verifier),
            code_challenge_method: verifier && "S256",
            login_hint: data[:loginHint] || data[:login_hint],
            prompt: options[:prompt]
          })
        end,
        validate_authorization_code: lambda do |data|
          Base.post_form("#{base}/token", {
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

          issuers = nil
          unless %w[common organizations consumers].include?(tenant_id.to_s)
            issuers = "#{authority.to_s.sub(%r{/+\z}, "")}/#{tenant_id}/v2.0"
          end
          profile = Base.verify_jwt_with_jwks(
            token,
            jwks: normalized[:jwks],
            jwks_endpoint: normalized[:jwks_endpoint] || "#{authority.to_s.sub(%r{/+\z}, "")}/#{tenant_id}/discovery/v2.0/keys",
            algorithms: ["RS256"],
            issuers: issuers,
            audience: Array(client_id),
            nonce: nonce
          )

          tid = profile&.fetch("tid", nil)
          next false unless tid.is_a?(String)
          next false unless profile["iss"] == "#{authority.to_s.sub(%r{/+\z}, "")}/#{tid}/v2.0"
          next false if tenant_id.to_s == "organizations" && tid == MICROSOFT_CONSUMER_TENANT_ID
          next false if tenant_id.to_s == "consumers" && tid != MICROSOFT_CONSUMER_TENANT_ID

          !!(profile&.fetch("sub", nil) || profile&.fetch("oid", nil))
        end,
        get_user_info: lambda do |tokens|
          custom = normalized[:get_user_info]
          next custom.call(tokens) if custom

          profile = Base.id_token(tokens) ? Base.decode_jwt_payload(Base.id_token(tokens)) : {}
          profile = Base.get_json("https://graph.microsoft.com/v1.0/me", "Authorization" => "Bearer #{Base.access_token(tokens)}") if profile.empty?
          unless normalized[:disable_profile_photo]
            photo_size = normalized[:profile_photo_size] || 48
            photo = Base.get_bytes(
              "https://graph.microsoft.com/v1.0/me/photos/#{photo_size}x#{photo_size}/$value",
              "Authorization" => "Bearer #{Base.access_token(tokens)}"
            )
            profile["picture"] = "data:image/jpeg;base64, #{Base64.strict_encode64(photo)}" if photo
          end
          email = profile["email"] || profile["mail"] || profile["userPrincipalName"] || profile["preferred_username"]

          user = Base.apply_profile_mapping(
            {
              id: profile["sub"] || profile["id"] || profile["oid"],
              email: email,
              name: profile["name"] || profile["displayName"],
              image: profile["picture"],
              emailVerified: microsoft_email_verified?(profile, email)
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
          Base.refresh_access_token(
            "#{base}/token",
            refresh_token,
            client_id: primary_client_id,
            client_secret: client_secret,
            extra_params: {scope: Base.selected_scopes(scopes, normalized, {}).join(" ")}
          )
        end
      }
    end

    def microsoft_email_verified?(profile, email)
      return !!profile["email_verified"] if profile.key?("email_verified")

      Array(profile["verified_primary_email"]).include?(email) ||
        Array(profile["verified_secondary_email"]).include?(email)
    end
  end
end
