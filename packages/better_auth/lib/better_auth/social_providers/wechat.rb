# frozen_string_literal: true

module BetterAuth
  module SocialProviders
    module_function

    def wechat(client_id:, client_secret:, scopes: ["snsapi_login"], **options)
      normalized = Base.normalize_options(options)
      provider = Base.oauth_provider(
        id: "wechat",
        name: "WeChat",
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: "https://open.weixin.qq.com/connect/qrconnect",
        token_endpoint: "https://api.weixin.qq.com/sns/oauth2/access_token",
        user_info_endpoint: "https://api.weixin.qq.com/sns/userinfo",
        scopes: scopes,
        scope_separator: ",",
        profile_map: ->(profile) {
          id = profile["unionid"] || profile["openid"]
          {
            id: id,
            name: profile["nickname"],
            email: profile["email"] || "#{id}@wechat.invalid",
            image: profile["headimgurl"],
            emailVerified: false
          }
        },
        **options
      )
      provider[:create_authorization_url] = lambda do |data|
        "#{Base.authorization_url("https://open.weixin.qq.com/connect/qrconnect", {
          appid: client_id,
          redirect_uri: normalized[:redirect_uri] || data[:redirect_uri] || data[:redirectURI],
          response_type: "code",
          scope: Base.selected_scopes(scopes, normalized, data).join(","),
          state: data[:state],
          lang: options[:lang] || "cn"
        })}#wechat_redirect"
      end
      provider[:validate_authorization_code] = lambda do |data|
        url = Base.authorization_url("https://api.weixin.qq.com/sns/oauth2/access_token", {
          appid: client_id,
          secret: client_secret,
          code: data[:code],
          grant_type: "authorization_code"
        })
        payload = Base.get_json(url)
        if !payload || payload["errcode"]
          raise Error, "Failed to validate authorization code: #{payload&.fetch("errmsg", nil) || "Unknown error"}"
        end

        Base.normalize_tokens(payload).merge(
          "openid" => payload["openid"],
          "unionid" => payload["unionid"]
        ).compact
      end
      provider[:refresh_access_token] = normalized[:refresh_access_token] || lambda do |refresh_token|
        url = Base.authorization_url("https://api.weixin.qq.com/sns/oauth2/refresh_token", {
          appid: client_id,
          grant_type: "refresh_token",
          refresh_token: refresh_token
        })
        payload = Base.get_json(url)
        if !payload || payload["errcode"]
          raise Error, "Failed to refresh access token: #{payload&.fetch("errmsg", nil) || "Unknown error"}"
        end

        Base.normalize_tokens(payload).merge(
          "openid" => payload["openid"],
          "unionid" => payload["unionid"]
        ).compact
      end
      provider[:get_user_info] = lambda do |tokens|
        custom = normalized[:get_user_info]
        next custom.call(tokens) if custom

        openid = tokens["openid"] || tokens[:openid]
        next nil if openid.to_s.empty?

        url = Base.authorization_url("https://api.weixin.qq.com/sns/userinfo", {
          access_token: Base.access_token(tokens),
          openid: openid,
          lang: "zh_CN"
        })
        profile = Base.get_json(url)
        next nil if !profile || profile["errcode"]

        id = profile["unionid"] || profile["openid"] || openid
        user = Base.apply_profile_mapping(
          {
            id: id,
            name: profile["nickname"],
            email: profile["email"] || "#{id}@wechat.invalid",
            image: profile["headimgurl"],
            emailVerified: false
          },
          profile,
          normalized
        )
        {user: user, data: profile}
      end
      provider
    end
  end
end
