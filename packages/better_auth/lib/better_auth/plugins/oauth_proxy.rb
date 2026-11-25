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
              handler: ->(ctx) { oauth_proxy_intercept_social_callback(ctx, config) }
            }
          ],
          after: [
            {
              matcher: ->(ctx) { oauth_proxy_sign_in_path?(ctx.path) },
              handler: ->(ctx) { oauth_proxy_after_sign_in(ctx, config) }
            },
            {
              matcher: ->(ctx) { oauth_proxy_social_callback_path?(ctx.path) },
              handler: ->(ctx) { oauth_proxy_after_callback(ctx, config) }
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
        default_error_url = ctx.context.options.on_api_error[:error_url] || "#{ctx.context.options.base_url}/api/auth/error"
        encrypted_profile = query[:profile]
        if encrypted_profile.to_s.empty?
          raise oauth_proxy_redirect_error(ctx, default_error_url, "missing_profile")
        end

        oauth_proxy_complete_profile(ctx, config, encrypted_profile, default_error_url)
      end
    end

    def oauth_proxy_before_sign_in(ctx, config)
      return if oauth_proxy_skip?(ctx, config)
      return unless ctx.body.is_a?(Hash)

      ctx.oauth_redirect_base_url = "#{oauth_proxy_strip_trailing(config[:production_url])}#{ctx.context.options.base_path}" if config[:production_url]
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
      raise oauth_proxy_redirect_error(ctx, error_url, error) unless error.to_s.empty?

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
      rescue
        nil
      end
      raise oauth_proxy_redirect_error(ctx, error_url, "invalid_code") unless tokens

      user_info = Routes.call_provider(provider, :get_user_info, tokens)
      user = user_info[:user] || user_info["user"] if user_info
      raise oauth_proxy_redirect_error(ctx, error_url, "unable_to_get_user_info") unless user
      raise oauth_proxy_redirect_error(ctx, error_url, "email_not_found") if fetch_value(user, "email").to_s.empty?

      oauth_proxy_redirect_profile(
        ctx,
        config,
        state_data,
        package,
        user: oauth_proxy_social_user(user),
        account: oauth_proxy_social_account(provider_id, fetch_value(user, "id").to_s, Routes.token_hash(tokens)),
        disable_sign_up: Routes.provider_disable_sign_up?(provider) || (Routes.provider_disable_implicit_sign_up?(provider) && !state_data["requestSignUp"])
      )
    end

    def oauth_proxy_redirect_profile(ctx, config, state_data, package, user:, account:, disable_sign_up:)
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
    end

    def oauth_proxy_complete_profile(ctx, config, encrypted_profile, default_error_url)
      decrypted = Crypto.symmetric_decrypt(key: oauth_proxy_secret(ctx, config), data: encrypted_profile.to_s)
      raise oauth_proxy_redirect_error(ctx, default_error_url, "invalid_profile") unless decrypted

      payload = begin
        JSON.parse(decrypted)
      rescue JSON::ParserError
        nil
      end
      unless oauth_proxy_profile_payload?(payload)
        raise oauth_proxy_redirect_error(ctx, default_error_url, "invalid_payload")
      end

      error_url = payload["errorURL"] || default_error_url
      age = ((Time.now.to_f * 1000) - payload["timestamp"].to_f) / 1000
      if age > config[:max_age].to_i || age < -10
        raise oauth_proxy_redirect_error(ctx, error_url, "payload_expired")
      end
      begin
        OAuthState.parse_generic(ctx, payload["state"], cookie_name: nil, skip_state_cookie_check: true)
      rescue
        raise oauth_proxy_redirect_error(ctx, error_url, "state_mismatch")
      end

      account = payload.fetch("account")
      user = payload.fetch("userInfo")
      provider_id = fetch_value(account, "providerId").to_s
      account_id = fetch_value(account, "accountId").to_s
      session_data = begin
        Routes.persist_social_user(
          ctx,
          provider_id,
          user,
          Routes.token_hash_for_storage(ctx, account).merge("accountId" => account_id),
          callback_url: payload["callbackURL"],
          disable_sign_up: !!payload["disableSignUp"],
          override_user_info: false
        )
      rescue Routes::OAuthUserLookupError
        raise oauth_proxy_redirect_error(ctx, oauth_proxy_default_error_url(ctx), "internal_server_error")
      rescue APIError => error
        raise if error.status == "FOUND" || error.code.to_s.empty?

        raise oauth_proxy_redirect_error(ctx, error_url, error.code, error.message)
      end
      if session_data[:error]
        raise oauth_proxy_redirect_error(ctx, error_url, session_data[:error].tr(" ", "_"))
      end

      Cookies.set_session_cookie(ctx, session_data)
      final_url = if session_data[:new_user]
        payload["newUserURL"] || payload["callbackURL"]
      else
        payload["callbackURL"]
      end
      raise ctx.redirect(final_url)
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
      entry = Cookies.split_set_cookie_header(ctx.response_headers["set-cookie"]).filter_map { |line| Cookies.parse_set_cookie(line) }.find { |parsed| parsed[:name] == cookie.name }
      entry&.fetch(:value)
    end

    def oauth_proxy_plaintext_state(ctx, state)
      if OAuthState.cookie_strategy?(ctx)
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
      if state_data.key?("oauthState") && state_data["oauthState"] != package["state"]
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
      ctx.redirect(Routes.oauth_error_url(base_url, error, description))
    end

    def oauth_proxy_secret(ctx, config)
      config[:secret] || ctx.context.secret_config
    end

    def oauth_proxy_sign_in_path?(path)
      path.to_s.start_with?("/sign-in/social", "/sign-in/oauth2")
    end

    def oauth_proxy_social_callback_path?(path)
      %r{\A/callback/[^/]+\z}.match?(path)
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

    def oauth_proxy_strip_trailing(value)
      value.to_s.sub(%r{/+\z}, "")
    end

    def oauth_proxy_validate_callback!(ctx, callback_url)
      return if callback_url.to_s.empty?
      return if ctx.context.trusted_origin?(callback_url.to_s, allow_relative_paths: true)

      raise APIError.new("FORBIDDEN", message: "Invalid callbackURL")
    end

    def oauth_proxy_after_callback(ctx, config)
      location = ctx.response_headers["location"].to_s
      return unless location.start_with?("http") && location.include?("/oauth-proxy-callback?callbackURL")

      uri = URI.parse(location)
      return unless uri.origin == oauth_proxy_production_uri(ctx, config).origin

      destination = Rack::Utils.parse_query(uri.query)["callbackURL"]
      raise ctx.redirect(destination) unless destination.to_s.empty?
    end
  end
end
