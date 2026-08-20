# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def discord(client_id:, client_secret: nil, scopes: ["identify", "email"], **options)
      normalized = Base.normalize_options(options)
      {
        id: "discord",
        name: "Discord",
        client_id: client_id,
        client_secret: client_secret,
        create_authorization_url: lambda do |data|
          selected_scopes = Base.selected_scopes(scopes, normalized, data)
          params = {
            client_id: client_id,
            redirect_uri: data[:redirect_uri] || data[:redirectURI],
            response_type: "code",
            scope: selected_scopes,
            state: data[:state],
            prompt: options.fetch(:prompt, "none")
          }
          params[:permissions] = options[:permissions] if selected_scopes.include?("bot") && options.key?(:permissions)
          Base.authorization_url("https://discord.com/api/oauth2/authorize", params)
        end,
        validate_authorization_code: lambda do |data|
          Base.post_form("https://discord.com/api/oauth2/token", {
            client_id: client_id,
            client_secret: client_secret,
            code: data[:code],
            grant_type: "authorization_code",
            redirect_uri: data[:redirect_uri] || data[:redirectURI]
          })
        end,
        get_user_info: lambda do |tokens|
          custom = normalized[:get_user_info]
          next custom.call(tokens) if custom

          profile = Base.get_json("https://discord.com/api/users/@me", "Authorization" => "Bearer #{Base.access_token(tokens)}")
          image = discord_avatar_url(profile)
          profile["image_url"] = image
          user = Base.apply_profile_mapping(
            {
              id: profile["id"],
              email: profile["email"],
              name: profile["global_name"] || profile["username"] || "",
              image: image,
              emailVerified: !!profile["verified"]
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
          Base.refresh_access_token("https://discord.com/api/oauth2/token", refresh_token, client_id: client_id, client_secret: client_secret)
        end
      }
    end

    def discord_avatar_url(profile)
      avatar = profile["avatar"]
      unless avatar
        discriminator = profile["discriminator"].to_s
        default_avatar_number = if discriminator == "0"
          (profile["id"].to_i >> 22) % 6
        else
          discriminator.to_i % 5
        end
        return "https://cdn.discordapp.com/embed/avatars/#{default_avatar_number}.png"
      end

      format = avatar.start_with?("a_") ? "gif" : "png"
      "https://cdn.discordapp.com/avatars/#{profile["id"]}/#{avatar}.#{format}"
    end
  end
end
