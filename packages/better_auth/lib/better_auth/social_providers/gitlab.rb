# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def gitlab(client_id:, client_secret: nil, issuer: "https://gitlab.com", scopes: ["read_user"], **options)
      base = issuer.to_s.sub(%r{/+\z}, "")
      normalized = Base.normalize_options(options)
      {
        id: "gitlab",
        name: "GitLab",
        client_id: client_id,
        client_secret: client_secret,
        create_authorization_url: lambda do |data|
          Base.authorization_url(options[:authorization_endpoint] || "#{base}/oauth/authorize", {
            client_id: client_id,
            redirect_uri: data[:redirect_uri] || data[:redirectURI],
            response_type: "code",
            scope: Base.selected_scopes(scopes, normalized, data),
            state: data[:state],
            code_challenge: (data[:code_verifier] || data[:codeVerifier]) && Base.pkce_challenge(data[:code_verifier] || data[:codeVerifier]),
            code_challenge_method: (data[:code_verifier] || data[:codeVerifier]) && "S256",
            login_hint: data[:loginHint] || data[:login_hint]
          })
        end,
        validate_authorization_code: lambda do |data|
          Base.post_form("#{base}/oauth/token", {
            client_id: client_id,
            client_secret: client_secret,
            code: data[:code],
            code_verifier: data[:code_verifier] || data[:codeVerifier],
            grant_type: "authorization_code",
            redirect_uri: data[:redirect_uri] || data[:redirectURI]
          })
        end,
        get_user_info: lambda do |tokens|
          custom = normalized[:get_user_info]
          next custom.call(tokens) if custom

          profile = Base.get_json("#{base}/api/v4/user", "Authorization" => "Bearer #{Base.access_token(tokens)}")
          return nil if profile["state"] && profile["state"] != "active"
          return nil if profile["locked"] == true

          user = Base.apply_profile_mapping(
            {
              id: profile["id"].to_s,
              email: profile["email"],
              name: profile["name"] || profile["username"],
              image: profile["avatar_url"],
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
          Base.refresh_access_token("#{base}/oauth/token", refresh_token, client_id: client_id, client_secret: client_secret)
        end
      }
    end
  end
end
