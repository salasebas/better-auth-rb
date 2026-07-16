# frozen_string_literal: true

require "json"
require "uri"

module BetterAuth
  module Plugins
    OAUTH_POPUP_MESSAGE_TYPE = "better-auth:oauth-popup"
    OAUTH_POPUP_DATA_ELEMENT_ID = "better-auth-oauth-popup"
    OAUTH_POPUP_MARKER_COOKIE = "oauth_popup"
    OAUTH_POPUP_ERROR_CODES = {
      "POPUP_SIGN_IN_FAILED" => "Popup sign-in failed",
      "POPUP_BLOCKED" => "Sign-in popup was blocked by the browser",
      "POPUP_CLOSED" => "Sign-in popup was closed before completing",
      "POPUP_TIMEOUT" => "Sign-in popup timed out"
    }.freeze
    OAUTH_POPUP_INTERNAL_STATE_KEYS = OAuthState::INTERNAL_KEYS
    OAUTH_POPUP_COMPLETE_SCRIPT = [
      "(function () {",
      "\tvar el = document.getElementById(\"better-auth-oauth-popup\");",
      "\tif (!el) return;",
      "\tvar payload;",
      "\ttry {",
      "\t\tpayload = JSON.parse(el.textContent || \"\");",
      "\t} catch (e) {",
      "\t\treturn;",
      "\t}",
      "\tvar target = window.opener || window.parent;",
      "\tif (target && target !== window) {",
      "\t\ttry {",
      "\t\t\ttarget.postMessage(",
      "\t\t\t\t{",
      "\t\t\t\t\ttype: payload.type,",
      "\t\t\t\t\tnonce: payload.nonce,",
      "\t\t\t\t\ttoken: payload.token,",
      "\t\t\t\t\tredirectTo: payload.redirectTo,",
      "\t\t\t\t\terror: payload.error,",
      "\t\t\t\t},",
      "\t\t\t\tpayload.targetOrigin,",
      "\t\t\t);",
      "\t\t} catch (e) {}",
      "\t}",
      "\twindow.close();",
      "})();",
      ""
    ].join("\n")
    OAUTH_POPUP_SCRIPT_CSP_HASH = "sha256-tIo2K8VBC9SnhvdZ+9GsGkQoZm+jm/JcxL+d+i8b8KQ="

    module_function

    def oauth_popup
      Plugin.new(
        id: "oauth-popup",
        endpoints: {
          oauth_popup_start: oauth_popup_start_endpoint
        },
        hooks: {
          after: [
            {
              matcher: ->(ctx) { oauth_popup_callback_path?(ctx.path) },
              handler: ->(ctx) { oauth_popup_after_callback(ctx) }
            }
          ]
        },
        error_codes: OAUTH_POPUP_ERROR_CODES
      )
    end

    def oauth_popup_start_endpoint
      Endpoint.new(
        path: "/oauth-popup/start",
        method: "GET",
        query_schema: Routes.request_query_schema(
          required_strings: %w[provider popupOrigin],
          optional_strings: %w[popupNonce callbackURL errorCallbackURL newUserCallbackURL scopes requestSignUp additionalData]
        ),
        metadata: {
          hide: true,
          openapi: {
            parameters: [
              {name: "provider", in: "query", required: true, schema: {type: "string"}},
              {name: "popupOrigin", in: "query", required: true, schema: {type: "string"}},
              {name: "popupNonce", in: "query", required: false, schema: {type: "string"}},
              {name: "callbackURL", in: "query", required: false, schema: {type: "string"}},
              {name: "errorCallbackURL", in: "query", required: false, schema: {type: "string"}},
              {name: "newUserCallbackURL", in: "query", required: false, schema: {type: "string"}},
              {name: "scopes", in: "query", required: false, schema: {type: "string"}},
              {name: "requestSignUp", in: "query", required: false, schema: {type: "string"}},
              {name: "additionalData", in: "query", required: false, schema: {type: "string"}}
            ]
          }
        }
      ) do |ctx|
        query = normalize_hash(ctx.query)
        popup_origin = oauth_popup_validate_origin!(ctx, query[:popup_origin].to_s)

        nonce = query[:popup_nonce].to_s
        invalid_redirect = oauth_popup_invalid_redirect(ctx, query, popup_origin, nonce)
        next invalid_redirect if invalid_redirect

        provider_id = query[:provider].to_s
        provider = Routes.social_provider(ctx.context, provider_id)
        unless provider
          next oauth_popup_completion(ctx, popup_origin, nonce: nonce, error: {
            code: "provider_not_found",
            description: "Unknown provider: #{provider_id}"
          })
        end

        code_verifier = Crypto.random_string(128)
        scopes = query[:scopes]&.to_s&.split(",")
        additional_data = oauth_popup_additional_data(query[:additional_data])
        callback_url = query[:callback_url].to_s
        callback_url = ctx.context.base_url if callback_url.empty?
        request_sign_up = (query[:request_sign_up].to_s == "true") ? true : nil

        begin
          authorization_url = if (start = fetch_value(provider, "oauthPopupAuthorizationUrl")).respond_to?(:call)
            start.call(
              ctx,
              callbackURL: callback_url,
              errorCallbackURL: query[:error_callback_url],
              newUserCallbackURL: query[:new_user_callback_url],
              requestSignUp: request_sign_up,
              scopes: scopes,
              additionalData: additional_data,
              codeVerifier: code_verifier
            )
          else
            state_data = additional_data.merge(
              "callbackURL" => callback_url,
              "errorURL" => query[:error_callback_url],
              "newUserURL" => query[:new_user_callback_url],
              "requestSignUp" => request_sign_up,
              "codeVerifier" => code_verifier,
              "expiresAt" => Time.now.to_i + 600
            ).compact
            state = OAuthState.generate(ctx, state_data)
            Routes.call_provider(provider, :create_authorization_url, {
              state: state,
              codeVerifier: code_verifier,
              code_verifier: code_verifier,
              redirectURI: "#{ctx.context.canonical_base_url}/callback/#{provider_id}",
              redirect_uri: "#{ctx.context.canonical_base_url}/callback/#{provider_id}",
              scopes: scopes
            })
          end

          oauth_popup_set_marker(ctx, popup_origin, nonce)
        rescue => error
          oauth_popup_log(ctx.context, :error, "OAuth popup failed to start", error)
          next oauth_popup_completion(ctx, popup_origin, nonce: nonce, error: {
            code: "popup_sign_in_failed",
            description: "Failed to start the OAuth flow."
          })
        end

        raise ctx.redirect(authorization_url.to_s)
      end
    end

    def oauth_popup_validate_origin!(ctx, popup_origin)
      uri = URI.parse(popup_origin)
      valid_scheme = %w[http https].include?(uri.scheme)
      valid_path = uri.path.to_s.empty? || uri.path == "/"
      absolute = valid_scheme && !uri.host.to_s.empty?
      canonical = Configuration.origin_for(uri) if absolute
      valid = absolute &&
        uri.userinfo.nil? &&
        valid_path &&
        uri.query.nil? &&
        uri.fragment.nil? &&
        !popup_origin.match?(/[?*]/) &&
        ctx.context.trusted_origin?(canonical, allow_relative_paths: false)
      return canonical if valid

      oauth_popup_log(ctx.context, :error, "OAuth popup origin is not trusted")
      raise APIError.new("FORBIDDEN", code: "INVALID_ORIGIN", message: BASE_ERROR_CODES["INVALID_ORIGIN"])
    rescue URI::InvalidURIError
      raise APIError.new("FORBIDDEN", code: "INVALID_ORIGIN", message: BASE_ERROR_CODES["INVALID_ORIGIN"])
    end

    def oauth_popup_invalid_redirect(ctx, query, popup_origin, nonce)
      {
        callback_url: "invalid_callback_url",
        error_callback_url: "invalid_error_callback_url",
        new_user_callback_url: "invalid_new_user_callback_url"
      }.each do |key, code|
        value = query[key]
        next if value.to_s.empty?
        next if ctx.context.trusted_origin?(value.to_s, allow_relative_paths: true)

        oauth_popup_log(ctx.context, :error, "OAuth popup redirect URL is not trusted")
        return oauth_popup_completion(ctx, popup_origin, nonce: nonce, error: {
          code: code,
          description: "Untrusted redirect URL"
        })
      end
      nil
    end

    def oauth_popup_additional_data(value)
      parsed = value.is_a?(Hash) ? value : JSON.parse(value.to_s)
      return {} unless parsed.is_a?(Hash)

      parsed.reject { |key, _entry| OAUTH_POPUP_INTERNAL_STATE_KEYS.include?(key.to_s) }
    rescue JSON::ParserError
      {}
    end

    def oauth_popup_set_marker(ctx, popup_origin, nonce)
      cookie = ctx.context.create_auth_cookie(OAUTH_POPUP_MARKER_COOKIE, max_age: 600)
      ctx.set_signed_cookie(
        cookie.name,
        JSON.generate({popupOrigin: popup_origin, popupNonce: nonce}),
        ctx.context.secret,
        cookie.attributes
      )
    end

    def oauth_popup_callback_path?(path)
      path.to_s.start_with?("/callback/", "/oauth2/callback/")
    end

    def oauth_popup_after_callback(ctx)
      location = ctx.response_headers["location"].to_s
      return if location.empty?

      marker_cookie = ctx.context.create_auth_cookie(OAUTH_POPUP_MARKER_COOKIE)
      marker = ctx.get_signed_cookie(marker_cookie.name, ctx.context.secret)
      return unless marker

      Cookies.expire_cookie(ctx, marker_cookie)
      data = JSON.parse(marker)
      popup_origin = data.fetch("popupOrigin").to_s
      nonce = data["popupNonce"].to_s
      return if popup_origin.empty?

      token = oauth_popup_session_token(ctx)
      message = if token
        {nonce: nonce, token: token, redirectTo: location}
      else
        error = oauth_popup_redirect_error(location)
        return unless error

        {nonce: nonce, error: error}
      end

      oauth_popup_completion(ctx, popup_origin, message)
    rescue JSON::ParserError, KeyError
      nil
    end

    def oauth_popup_session_token(ctx)
      name = ctx.context.auth_cookies[:session_token].name
      Cookies.split_set_cookie_header(ctx.response_headers["set-cookie"]).each do |line|
        cookie = Cookies.parse_set_cookie(line)
        next unless cookie && cookie[:name] == name
        max_age = cookie.dig(:attributes, "max-age")
        next if cookie[:value].empty? || (max_age.to_s.strip.match?(/\A[+-]?\d+\z/) && max_age.to_i == 0)

        return URI.decode_uri_component(cookie[:value])
      rescue ArgumentError
        return cookie[:value]
      end
      nil
    end

    def oauth_popup_redirect_error(location)
      uri = URI.parse(location)
      params = URI.decode_www_form(uri.query.to_s).to_h
      return if params["error"].to_s.empty?

      {code: params["error"], description: params["error_description"]}.compact
    rescue URI::InvalidURIError
      nil
    end

    def oauth_popup_completion(ctx, popup_origin, message)
      oauth_popup_warn_missing_bearer(ctx) if message[:token]
      payload = {
        type: OAUTH_POPUP_MESSAGE_TYPE,
        targetOrigin: popup_origin
      }.merge(message)
      serialized = JSON.generate(payload)
        .gsub("<", "\\u003c")
        .gsub("\u2028", "\\u2028")
        .gsub("\u2029", "\\u2029")
      html = <<~HTML
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>Completing sign-in</title></head>
        <body>
        <script type="application/json" id="#{OAUTH_POPUP_DATA_ELEMENT_ID}">#{serialized}</script>
        <script>#{OAUTH_POPUP_COMPLETE_SCRIPT}</script>
        </body>
        </html>
      HTML
      headers = ctx.response_headers.merge(
        "content-type" => "text/html; charset=utf-8",
        "content-security-policy" => "default-src 'none'; script-src '#{OAUTH_POPUP_SCRIPT_CSP_HASH}'; base-uri 'none'",
        "cache-control" => "no-store",
        "pragma" => "no-cache"
      )
      headers.delete("location")
      Endpoint::Result.new(response: html, status: 200, headers: headers)
    end

    def oauth_popup_warn_missing_bearer(ctx)
      return if ctx.context.options.plugins.any? { |plugin| plugin.id == "bearer" }
      return if @oauth_popup_warned_missing_bearer

      @oauth_popup_warned_missing_bearer = true
      oauth_popup_log(
        ctx.context,
        :warn,
        "OAuth popup hands the session token back via postMessage, but the `bearer` plugin is not registered. Add bearer() for embedded cross-site authentication."
      )
    end

    def oauth_popup_log(context, level, message, *details)
      logger = context.logger
      if logger.respond_to?(:call)
        logger.call(level, message, *details)
      elsif logger.respond_to?(level)
        logger.public_send(level, message, *details)
      end
    end
  end
end
