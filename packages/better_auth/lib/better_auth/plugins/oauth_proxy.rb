# frozen_string_literal: true

require "json"
require "rack/utils"
require "uri"

module BetterAuth
  module Plugins
    module_function

    def oauth_proxy(options = {})
      config = {max_age: 60}.merge(normalize_hash(options))

      Plugin.new(
        id: "oauth-proxy",
        endpoints: {
          oauth_proxy: oauth_proxy_endpoint(config)
        },
        hooks: {
          before: [
            {
              matcher: ->(ctx) { oauth_proxy_sign_in_path?(ctx.path) },
              handler: ->(ctx) { oauth_proxy_before_sign_in(ctx, config) }
            },
            {
              matcher: ->(ctx) { oauth_proxy_social_callback_path?(ctx.path) },
              handler: ->(ctx) { oauth_proxy_handle_social_callback(ctx, config) }
            },
            {
              matcher: ->(ctx) { oauth_proxy_generic_callback_path?(ctx.path) },
              handler: ->(ctx) { oauth_proxy_handle_generic_callback(ctx, config) }
            }
          ],
          after: [
            {
              matcher: ->(ctx) { oauth_proxy_sign_in_path?(ctx.path) },
              handler: ->(ctx) { oauth_proxy_after_sign_in(ctx, config) }
            }
          ]
        },
        options: config
      )
    end

    def oauth_proxy_endpoint(config)
      Endpoint.new(
        path: "/oauth-proxy-callback",
        method: "GET",
        metadata: {
          openapi: {
            operationId: "oauthProxyCallback",
            description: "OAuth Proxy Callback",
            parameters: [
              {in: "query", name: "callbackURL", required: true, schema: {type: "string", format: "uri"}},
              {in: "query", name: "profile", required: false, schema: {type: "string"}}
            ],
            responses: {
              "302" => {description: "Redirects to the callback URL"}
            }
          }
        }
      ) do |ctx|
        query = normalize_hash(ctx.query)
        callback_url = query[:callback_url] || "/"
        oauth_proxy_validate_callback!(ctx, callback_url)
        encrypted_profile = query[:profile]
        if encrypted_profile.to_s.empty?
          raise oauth_proxy_redirect_error(ctx, oauth_proxy_default_error_url(ctx), "missing_profile")
        end

        oauth_proxy_complete_profile(ctx, config, encrypted_profile)
      end
    end

    def oauth_proxy_before_sign_in(ctx, config)
      return if oauth_proxy_skip?(ctx, config)
      return unless ctx.body.is_a?(Hash)

      if oauth_proxy_social_sign_in_path?(ctx.path)
        ctx.instance_variable_set(:@oauth_proxy_state, true)
      end
      ctx.instance_variable_set(:@oauth_proxy_redirect_uri, oauth_proxy_production_redirect_base(ctx, config))
      original_callback = ctx.body["callbackURL"] || ctx.body["callbackUrl"] || ctx.body["callback_url"] || ctx.body[:callbackURL] || ctx.body[:callback_url] || ctx.context.base_url
      current = oauth_proxy_current_uri(ctx, config)
      callback = "#{oauth_proxy_strip_trailing(current.origin)}#{ctx.context.options.base_path}/oauth-proxy-callback?callbackURL=#{URI.encode_www_form_component(original_callback)}"
      ctx.body = ctx.body.merge("callbackURL" => callback, :callback_url => callback)
      nil
    end

    def oauth_proxy_intercept_social_callback(ctx, config)
      callback, package, state_data, error_url = oauth_proxy_callback_state(ctx, config)
      return unless package

      error = callback[:error]
      raise oauth_proxy_redirect_error(ctx, error_url, error, callback[:error_description]) if error

      code = callback[:code].to_s
      raise oauth_proxy_redirect_error(ctx, error_url, "no_code") if code.empty?

      provider_id = (fetch_value(ctx.params, "id") || fetch_value(ctx.params, "providerId")).to_s
      provider = Routes.social_provider(ctx.context, provider_id)
      raise oauth_proxy_redirect_error(ctx, error_url, "oauth_provider_not_found") unless provider

      tokens = begin
        Routes.call_provider(provider, :validate_authorization_code, {
          code: code,
          codeVerifier: state_data["codeVerifier"],
          code_verifier: state_data["codeVerifier"],
          redirectURI: "#{ctx.context.canonical_base_url}/callback/#{provider_id}",
          redirect_uri: "#{ctx.context.canonical_base_url}/callback/#{provider_id}"
        })
      rescue APIError => error
        raise if error.status == "FOUND"

        nil
      rescue
        nil
      end
      raise oauth_proxy_redirect_error(ctx, error_url, "invalid_code") unless tokens

      token_data = Routes.token_hash(tokens)
      token_data["user"] = Routes.parse_json_hash(callback[:user]) if callback[:user]
      user_info = Routes.call_provider(provider, :get_user_info, token_data)
      user = user_info[:user] || user_info["user"] if user_info
      raise oauth_proxy_redirect_error(ctx, error_url, "unable_to_get_user_info") unless user
      raise oauth_proxy_redirect_error(ctx, error_url, "email_not_found") if fetch_value(user, "email").to_s.empty?
      raise oauth_proxy_redirect_error(ctx, error_url, "unable_to_get_user_info") if Routes.blank_remote_id?(fetch_value(user, "id"))

      oauth_proxy_redirect_profile(
        ctx,
        config,
        state_data,
        package,
        user: oauth_proxy_social_user(user),
        account: oauth_proxy_social_account(provider_id, fetch_value(user, "id").to_s, token_data),
        disable_sign_up: Routes.provider_disable_sign_up?(provider) || (Routes.provider_disable_implicit_sign_up?(provider) && !state_data["requestSignUp"])
      )
    end

    def oauth_proxy_handle_social_callback(ctx, config)
      oauth_proxy_intercept_social_callback(ctx, config)
    end

    def oauth_proxy_intercept_generic_callback(ctx, config)
      callback, package, state_data, error_url = oauth_proxy_callback_state(ctx, config)
      return unless package

      provider_id = (fetch_value(ctx.params, "providerId") || callback[:provider_id]).to_s
      provider = oauth_proxy_generic_provider(ctx, provider_id)
      return unless provider

      redirect_error = ->(error, description = nil) { raise oauth_proxy_redirect_error(ctx, error_url, error, description) }
      redirect_error.call(callback[:error] || "oAuth_code_missing", callback[:error_description]) if callback[:error] || callback[:code].to_s.empty?
      generic_oauth_validate_issuer!(ctx, provider, callback, redirect_error)

      tokens = begin
        generic_oauth_exchange_token(ctx, provider, callback[:code].to_s, state_data)
      rescue
        nil
      end
      redirect_error.call("oauth_code_verification_failed") unless tokens

      user_info = generic_oauth_user_info(provider, tokens)
      redirect_error.call("user_info_is_missing") unless user_info

      user = generic_oauth_map_user(provider, user_info)
      email = fetch_value(user, "email").to_s.downcase
      name = fetch_value(user, "name").to_s
      account_id = fetch_value(user, "id").to_s
      redirect_error.call("email_is_missing") if email.empty?
      redirect_error.call("id_is_missing") if account_id.empty?
      redirect_error.call("name_is_missing") if name.empty?

      existing = ctx.context.internal_adapter.find_oauth_user(email, account_id, provider_id)
      if !existing && (provider[:disable_sign_up] || (provider[:disable_implicit_sign_up] && !state_data["requestSignUp"]))
        redirect_error.call("signup_disabled")
      end

      oauth_proxy_redirect_profile(
        ctx,
        config,
        state_data,
        package,
        user: oauth_proxy_generic_user(user, email, name, account_id),
        account: oauth_proxy_generic_account(provider_id, account_id, tokens),
        disable_sign_up: false,
        override_user_info: provider[:override_user_info],
        generic_oauth: true
      )
    end

    def oauth_proxy_handle_generic_callback(ctx, config)
      oauth_proxy_intercept_generic_callback(ctx, config)
    end

    def oauth_proxy_redirect_profile(ctx, config, state_data, package, user:, account:, disable_sign_up:, override_user_info: false, generic_oauth: false)
      proxy_callback = URI.parse(state_data.fetch("callbackURL"))
      final_callback = Rack::Utils.parse_query(proxy_callback.query).fetch("callbackURL", state_data.fetch("callbackURL"))
      payload = {
        userInfo: user,
        account: account,
        state: package.fetch("state"),
        callbackURL: final_callback,
        newUserURL: state_data["newUserURL"] || state_data["newUserCallbackURL"],
        errorURL: state_data["errorURL"] || state_data["errorCallbackURL"],
        disableSignUp: disable_sign_up,
        overrideUserInfo: override_user_info,
        genericOAuth: generic_oauth,
        timestamp: (Time.now.to_f * 1000).to_i
      }.compact
      encrypted_profile = Crypto.symmetric_encrypt(
        key: oauth_proxy_secret(ctx, config),
        data: JSON.generate(payload)
      )
      callback_params = Rack::Utils.parse_query(proxy_callback.query)
      callback_params["profile"] = encrypted_profile
      proxy_callback.query = URI.encode_www_form(callback_params)
      raise ctx.redirect(proxy_callback.to_s)
    rescue URI::InvalidURIError, KeyError
      raise oauth_proxy_redirect_error(ctx, oauth_proxy_default_error_url(ctx), "state_mismatch")
    end

    def oauth_proxy_complete_profile(ctx, config, encrypted_profile)
      decrypted = Crypto.symmetric_decrypt(key: oauth_proxy_secret(ctx, config), data: encrypted_profile.to_s)
      raise oauth_proxy_redirect_error(ctx, oauth_proxy_default_error_url(ctx), "invalid_profile") unless decrypted

      payload = JSON.parse(decrypted)
      unless oauth_proxy_profile_payload?(payload)
        raise oauth_proxy_redirect_error(ctx, oauth_proxy_default_error_url(ctx), "invalid_payload")
      end

      error_url = payload["errorURL"] || oauth_proxy_default_error_url(ctx)
      age = ((Time.now.to_f * 1000) - payload["timestamp"].to_f) / 1000
      if age > config[:max_age].to_i || age < -10
        raise oauth_proxy_redirect_error(ctx, error_url, "payload_expired")
      end
      begin
        OAuthState.parse(ctx, payload["state"], skip_state_cookie_check: true)
      rescue OAuthState::Error
        raise oauth_proxy_redirect_error(ctx, error_url, "state_mismatch")
      end

      account = payload.fetch("account")
      user = payload.fetch("userInfo")
      provider_id = fetch_value(account, "providerId").to_s
      account_id = fetch_value(account, "accountId").to_s
      if provider_id.empty? || account_id.empty?
        raise oauth_proxy_redirect_error(ctx, error_url, "invalid_payload")
      end

      session_data = begin
        Routes.persist_social_user(
          ctx,
          provider_id,
          user,
          Routes.token_hash_for_storage(ctx, account).merge("accountId" => account_id),
          callback_url: payload["callbackURL"],
          disable_sign_up: !!payload["disableSignUp"],
          override_user_info: !!payload["overrideUserInfo"]
        )
      rescue APIError => error
        raise if error.code.to_s.empty?

        code = (error.code == "INTERNAL_SERVER_ERROR") ? "internal_server_error" : error.code
        raise oauth_proxy_redirect_error(ctx, error_url, code, error.message)
      end
      if session_data[:error]
        raise oauth_proxy_redirect_error(ctx, error_url, session_data[:error].tr(" ", "_"))
      end

      generic_oauth_set_account_cookie(ctx, provider_id, account_id, session_data[:user]["id"]) if payload["genericOAuth"]
      Cookies.set_session_cookie(ctx, session_data)
      final_url = if session_data[:new_user]
        payload["newUserURL"] || payload["callbackURL"]
      else
        payload["callbackURL"]
      end
      raise ctx.redirect(final_url)
    rescue JSON::ParserError, TypeError
      raise oauth_proxy_redirect_error(ctx, oauth_proxy_default_error_url(ctx), "invalid_payload")
    end

    def oauth_proxy_after_sign_in(ctx, config)
      return if oauth_proxy_skip?(ctx, config)
      return unless ctx.returned.is_a?(Hash)

      provider_url = fetch_value(ctx.returned, "url").to_s
      return if provider_url.empty?

      uri = URI.parse(provider_url)
      params = Rack::Utils.parse_query(uri.query)
      original_state = params["state"]
      return if original_state.to_s.empty?

      encrypted_state = begin
        plaintext_state = oauth_proxy_plaintext_state(ctx, original_state)
        unless plaintext_state.to_s.empty?
          state_cookie = Crypto.symmetric_encrypt(
            key: oauth_proxy_secret(ctx, config),
            data: plaintext_state
          )
          Crypto.symmetric_encrypt(
            key: oauth_proxy_secret(ctx, config),
            data: JSON.generate({
              state: original_state,
              stateCookie: state_cookie,
              isOAuthProxy: true
            })
          )
        end
      rescue
        nil
      end
      return unless encrypted_state

      params["state"] = encrypted_state
      uri.query = URI.encode_www_form(params)

      response = ctx.returned.dup
      response[response.key?(:url) ? :url : "url"] = uri.to_s
      ctx.returned = response
      ctx.json(response)
    rescue URI::InvalidURIError
      nil
    end

    def oauth_proxy_state_cookie_value(ctx)
      cookie = ctx.context.create_auth_cookie("oauth_state")
      parsed = oauth_proxy_parse_set_cookie(ctx.response_headers["set-cookie"])
      exact = parsed.find { |entry| entry[:name] == cookie.name || entry[:name] == Cookies.strip_secure_cookie_prefix(cookie.name) }
      exact && exact[:value]
    end

    def oauth_proxy_plaintext_state(ctx, state)
      if oauth_proxy_cookie_state_strategy?(ctx)
        encrypted_state = oauth_proxy_state_cookie_value(ctx)
        return if encrypted_state.to_s.empty?

        Crypto.symmetric_decrypt(key: ctx.context.secret_config, data: encrypted_state)
      else
        verification = ctx.context.internal_adapter.find_verification_value(state)
        verification && verification["value"]
      end
    end

    def oauth_proxy_state_package(ctx, config, state)
      return if state.to_s.empty?

      decrypted = Crypto.symmetric_decrypt(key: oauth_proxy_secret(ctx, config), data: state.to_s)
      return unless decrypted

      package = JSON.parse(decrypted)
      return unless package.is_a?(Hash)
      return unless package["isOAuthProxy"] && package["state"] && package["stateCookie"]

      package
    rescue JSON::ParserError
      nil
    end

    def oauth_proxy_callback_state(ctx, config)
      callback = normalize_hash(ctx.body).merge(normalize_hash(ctx.query))
      package = oauth_proxy_state_package(ctx, config, callback[:state])
      return unless package

      state_data = oauth_proxy_decrypt_state_data(ctx, config, package)
      return unless state_data

      error_url = oauth_proxy_state_error_url(ctx, state_data)
      expected_state = state_data["oauthState"] || state_data["state"]
      if expected_state && expected_state != package["state"]
        raise oauth_proxy_redirect_error(ctx, error_url, "state_mismatch")
      end

      [callback, package, state_data, error_url]
    end

    def oauth_proxy_social_user(user)
      {
        "id" => fetch_value(user, "id").to_s,
        "email" => fetch_value(user, "email"),
        "name" => fetch_value(user, "name").to_s,
        "image" => fetch_value(user, "image"),
        "emailVerified" => fetch_value(user, "emailVerified")
      }.compact
    end

    def oauth_proxy_social_account(provider_id, account_id, token_data)
      {
        "providerId" => provider_id,
        "accountId" => account_id,
        "accessToken" => fetch_value(token_data, "accessToken"),
        "refreshToken" => fetch_value(token_data, "refreshToken"),
        "idToken" => fetch_value(token_data, "idToken"),
        "accessTokenExpiresAt" => fetch_value(token_data, "accessTokenExpiresAt"),
        "refreshTokenExpiresAt" => fetch_value(token_data, "refreshTokenExpiresAt"),
        "scope" => fetch_value(token_data, "scope")
      }.compact
    end

    def oauth_proxy_generic_provider(ctx, provider_id)
      plugin = ctx.context.options.plugins.find { |entry| entry.id == "generic-oauth" }
      generic_oauth_provider(plugin.options, provider_id) if plugin
    end

    def oauth_proxy_generic_account(provider_id, account_id, tokens)
      data = normalize_hash(tokens || {})
      {
        "providerId" => provider_id,
        "accountId" => account_id,
        "accessToken" => data[:access_token] || data[:accessToken],
        "refreshToken" => data[:refresh_token] || data[:refreshToken],
        "idToken" => data[:id_token] || data[:idToken],
        "accessTokenExpiresAt" => data[:access_token_expires_at] || data[:accessTokenExpiresAt],
        "refreshTokenExpiresAt" => data[:refresh_token_expires_at] || data[:refreshTokenExpiresAt],
        "scope" => Array(data[:scopes] || data[:scope]).join(",")
      }.compact
    end

    def oauth_proxy_generic_user(user, email, name, account_id)
      normalize_hash(user).each_with_object({}) { |(key, value), data| data[key.to_s] = value }
        .merge("email" => email, "name" => name, "id" => account_id)
    end

    def oauth_proxy_decrypt_state_data(ctx, config, package)
      decrypted = Crypto.symmetric_decrypt(key: oauth_proxy_secret(ctx, config), data: package.fetch("stateCookie"))
      return unless decrypted

      data = JSON.parse(decrypted)
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, KeyError
      nil
    end

    def oauth_proxy_profile_payload?(payload)
      payload.is_a?(Hash) &&
        payload["timestamp"].is_a?(Numeric) &&
        payload["userInfo"].is_a?(Hash) &&
        payload["account"].is_a?(Hash) &&
        !payload["state"].to_s.empty? &&
        !payload["callbackURL"].to_s.empty?
    end

    def oauth_proxy_default_error_url(ctx)
      ctx.context.options.on_api_error[:error_url] || "#{oauth_proxy_strip_trailing(ctx.context.base_url)}/error"
    end

    def oauth_proxy_state_error_url(ctx, state_data)
      state_data["errorURL"] || state_data["errorCallbackURL"] || oauth_proxy_default_error_url(ctx)
    end

    def oauth_proxy_redirect_error(ctx, base_url, error, description = nil)
      uri = URI.parse(base_url.to_s)
      params = URI.decode_www_form(uri.query.to_s)
      params << ["error", error.to_s]
      params << ["error_description", description.to_s] if description
      uri.query = URI.encode_www_form(params)
      ctx.redirect(uri.to_s)
    end

    def oauth_proxy_secret(ctx, config)
      config[:secret] || ctx.context.secret_config
    end

    def oauth_proxy_sign_in_path?(path)
      path.to_s.start_with?("/sign-in/social", "/sign-in/oauth2")
    end

    def oauth_proxy_social_sign_in_path?(path)
      path.to_s.start_with?("/sign-in/social")
    end

    def oauth_proxy_social_callback_path?(path)
      path.to_s.start_with?("/callback")
    end

    def oauth_proxy_generic_callback_path?(path)
      path.to_s.start_with?("/oauth2/callback")
    end

    def oauth_proxy_cookie_state_strategy?(ctx)
      ctx.context.options.account[:store_state_strategy].to_s == "cookie"
    end

    def oauth_proxy_skip?(ctx, config)
      current = oauth_proxy_current_uri(ctx, config)
      production = oauth_proxy_production_uri(ctx, config)
      current.origin == production.origin
    rescue URI::InvalidURIError
      false
    end

    def oauth_proxy_current_uri(ctx, config)
      URI.parse((config[:current_url] || ctx.context.options.base_url || ctx.context.base_url).to_s)
    end

    def oauth_proxy_production_uri(ctx, config)
      URI.parse((config[:production_url] || ctx.context.options.base_url || ctx.context.base_url).to_s)
    end

    def oauth_proxy_production_redirect_base(ctx, config)
      production_url = config[:production_url] || ctx.context.options.base_url || ctx.context.base_url
      "#{oauth_proxy_strip_trailing(production_url)}#{ctx.context.options.base_path}"
    end

    def oauth_proxy_strip_trailing(value)
      value.to_s.sub(%r{/+\z}, "")
    end

    def oauth_proxy_validate_callback!(ctx, callback_url)
      return if callback_url.to_s.empty?
      return if ctx.context.trusted_origin?(callback_url.to_s, allow_relative_paths: true)

      raise APIError.new("FORBIDDEN", message: "Invalid callbackURL")
    end

    def oauth_proxy_parse_set_cookie(header)
      header.to_s.split(/\n|,(?=\s*[^;,]+=)/).filter_map do |line|
        parts = line.strip.split(/;\s*/)
        name, value = parts.shift.to_s.split("=", 2)
        next if name.to_s.empty?

        options = {}
        parts.each do |part|
          key, option_value = part.split("=", 2)
          case key.to_s.downcase
          when "path" then options[:path] = option_value
          when "expires" then options[:expires] = option_value
          when "samesite" then options[:same_site] = option_value
          when "httponly" then options[:http_only] = true
          when "secure" then options[:secure] = true
          when "max-age" then options[:max_age] = option_value
          end
        end
        {name: Cookies.strip_secure_cookie_prefix(name), value: URI.decode_www_form_component(value.to_s), options: options}
      end
    end
  end
end
