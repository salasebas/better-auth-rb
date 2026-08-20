# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def sso_sign_in_endpoint(config = {})
      Endpoint.new(path: "/sign-in/sso", method: "POST", metadata: sso_openapi_for(:sign_in)) do |ctx|
        body = normalize_hash(ctx.body)
        provider = sso_select_provider(ctx, body, config)
        provider_type = body[:provider_type].to_s
        if provider_type == "oidc" && !provider["oidcConfig"]
          raise APIError.new("BAD_REQUEST", message: "OIDC provider is not configured")
        end
        if provider_type == "saml" && !provider["samlConfig"]
          raise APIError.new("BAD_REQUEST", message: "SAML provider is not configured")
        end
        if config.dig(:domain_verification, :enabled) && !(provider.key?("domainVerified") && provider["domainVerified"])
          raise APIError.new("UNAUTHORIZED", message: "Provider domain has not been verified")
        end

        if provider["oidcConfig"] && provider_type != "saml"
          provider = sso_ensure_runtime_oidc_provider(ctx, provider, config)
          code_verifier = BetterAuth::Crypto.random_string(128)
          state_data = {
            callbackURL: body[:callback_url] || ctx.context.base_url,
            codeVerifier: code_verifier,
            errorURL: body[:error_callback_url],
            newUserURL: body[:new_user_callback_url],
            requestSignUp: body[:request_sign_up],
            expiresAt: Time.now.to_i + 600
          }
          state_data[:ssoProviderId] = provider.fetch("providerId") unless config[:redirect_uri].to_s.strip.empty?
          state = BetterAuth::OAuthState.generate(ctx, state_data.compact)
          url = sso_oidc_authorization_url(provider, ctx, state, config, body, code_verifier: code_verifier)
        elsif provider["samlConfig"]
          BetterAuth::SSO.load_saml!
          state_data = {
            providerId: provider.fetch("providerId"),
            callbackURL: body[:callback_url] || "/",
            errorURL: body[:error_callback_url],
            newUserURL: body[:new_user_callback_url],
            requestSignUp: body[:request_sign_up]
          }
          relay_state = sso_generate_saml_relay_state(ctx, state_data)
          url = sso_saml_authorization_url(provider, relay_state, ctx, config)
          sso_store_saml_authn_request(ctx, provider, url, config)
        else
          raise APIError.new("BAD_REQUEST", message: "OIDC provider is not configured")
        end
        ctx.json({url: url, redirect: true})
      end
    end

    def sso_oidc_callback_endpoint(config = {})
      Endpoint.new(path: "/sso/callback/:providerId", method: "GET") do |ctx|
        sso_handle_oidc_callback(ctx, config, sso_fetch(ctx.params, :provider_id))
      end
    end

    def sso_oidc_shared_callback_endpoint(config = {})
      Endpoint.new(path: "/sso/callback", method: "GET") do |ctx|
        state = begin
          sso_parse_oidc_state(ctx)
        rescue BetterAuth::OAuthState::Error => error
          next sso_oidc_state_error_response(ctx, error)
        end

        provider_id = state["ssoProviderId"] || state[:ssoProviderId]
        unless provider_id
          error_url = sso_safe_oidc_redirect_url(ctx, state["errorURL"] || state["callbackURL"] || ctx.context.base_url)
          next sso_redirect(ctx, sso_append_error(error_url, "invalid_state", "missing_provider_id"))
        end

        sso_handle_oidc_callback(ctx, config, provider_id, state: state)
      end
    end

    def sso_handle_oidc_callback(ctx, config, provider_id, state: nil)
      state ||= begin
        sso_parse_oidc_state(ctx)
      rescue BetterAuth::OAuthState::Error => error
        return sso_oidc_state_error_response(ctx, error)
      end

      callback_url = sso_safe_oidc_redirect_url(ctx, state["callbackURL"] || "/")
      error_url = sso_safe_oidc_redirect_url(ctx, state["errorURL"] || callback_url)
      if ctx.query[:error] || ctx.query["error"]
        error = ctx.query[:error] || ctx.query["error"]
        description = ctx.query[:error_description] || ctx.query["error_description"]
        return sso_redirect(ctx, sso_append_error(error_url, error, description))
      end
      provider = sso_callback_provider(ctx, config, provider_id)
      return sso_redirect(ctx, sso_append_error(error_url, "invalid_provider", "provider not found")) unless provider
      if config.dig(:domain_verification, :enabled) && !(provider.key?("domainVerified") && provider["domainVerified"])
        raise APIError.new("UNAUTHORIZED", message: "Provider domain has not been verified")
      end

      provider = sso_ensure_runtime_oidc_provider(ctx, provider, config)
      oidc_config = sso_provider_config_hash(provider["oidcConfig"])
      oidc_config[:issuer] ||= provider["issuer"]
      return sso_redirect(ctx, sso_append_error(error_url, "invalid_provider", "provider not found")) if oidc_config.empty?

      tokens = sso_oidc_tokens(ctx, provider, oidc_config, state, config)
      unless tokens
        return sso_redirect(ctx, sso_append_error(error_url, "invalid_provider", "token_response_not_found"))
      end
      if oidc_config[:user_info_endpoint].to_s.empty? && tokens[:id_token] && oidc_config[:jwks_endpoint].to_s.empty?
        begin
          provider = sso_ensure_runtime_oidc_provider(ctx, provider, config, require_jwks: true)
          oidc_config = sso_provider_config_hash(provider["oidcConfig"])
          oidc_config[:issuer] ||= provider["issuer"]
        rescue APIError
          # Fall through to the upstream callback error when JWKS is still unavailable.
        end
      end
      user_info = sso_oidc_user_info(ctx, oidc_config, tokens, config)
      if user_info[:_sso_error]
        return sso_redirect(ctx, sso_append_error(error_url, "invalid_provider", user_info[:_sso_error]))
      end
      if user_info[:email].to_s.empty? || user_info[:id].to_s.empty?
        return sso_redirect(ctx, sso_append_error(error_url, "invalid_provider", "missing_user_info"))
      end
      if config[:disable_implicit_sign_up] && !state["requestSignUp"] && !ctx.context.internal_adapter.find_user_by_email(user_info[:email].to_s.downcase)
        return sso_redirect(ctx, sso_append_error(error_url, "signup disabled"))
      end

      result = sso_find_or_create_user_result(ctx, provider, user_info, config)
      return sso_redirect(ctx, sso_append_error(error_url, result.fetch(:error))) if result[:error]

      if config[:provision_user].respond_to?(:call) && (result.fetch(:created) || config[:provision_user_on_every_login])
        config[:provision_user].call(user: result.fetch(:user), userInfo: user_info, token: tokens, provider: provider)
      end
      session = ctx.context.internal_adapter.create_session(result.fetch(:user).fetch("id"), false, nil, false, ctx)
      Cookies.set_session_cookie(ctx, {session: session, user: result.fetch(:user)})
      redirect_to = (result.fetch(:created) && state["newUserURL"].to_s != "") ? sso_safe_oidc_redirect_url(ctx, state["newUserURL"]) : callback_url
      sso_redirect(ctx, redirect_to || "/")
    rescue APIError => error
      raise unless error_url

      sso_redirect(ctx, sso_append_error(error_url, error.code, error.message))
    end

    def sso_parse_oidc_state(ctx)
      state = BetterAuth::OAuthState.parse(ctx, ctx.query[:state] || ctx.query["state"], allow_legacy: false)
      state["errorURL"] ||= ctx.context.options.on_api_error[:error_url] || "#{ctx.context.base_url}/error"
      state
    end

    def sso_oidc_state_error_response(ctx, error)
      error_url = error.error_url || ctx.context.options.on_api_error[:error_url] || "#{ctx.context.base_url}/error"
      sso_redirect(ctx, sso_append_error(error_url, error.code))
    end
  end
end
