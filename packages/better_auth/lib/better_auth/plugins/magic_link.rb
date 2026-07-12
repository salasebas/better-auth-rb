# frozen_string_literal: true

require "json"
require "uri"

module BetterAuth
  module Plugins
    module_function

    def magic_link(options = {})
      config = {store_token: "plain", allowed_attempts: 1}.merge(normalize_hash(options))

      Plugin.new(
        id: "magic-link",
        endpoints: {
          sign_in_magic_link: sign_in_magic_link_endpoint(config),
          magic_link_verify: magic_link_verify_endpoint(config)
        },
        rate_limit: [
          {
            path_matcher: ->(path) { path.start_with?("/sign-in/magic-link", "/magic-link/verify") },
            window: config.dig(:rate_limit, :window) || 60,
            max: config.dig(:rate_limit, :max) || 5
          }
        ],
        options: config
      )
    end

    def sign_in_magic_link_endpoint(config)
      Endpoint.new(
        path: "/sign-in/magic-link",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "signInMagicLink",
            description: "Send a magic sign-in link",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  email: {type: "string", description: "The email address to sign in"},
                  name: {type: ["string", "null"], description: "The user name to use when creating a new user"},
                  callbackURL: {type: ["string", "null"]},
                  errorCallbackURL: {type: ["string", "null"]},
                  newUserCallbackURL: {type: ["string", "null"]},
                  metadata: {type: ["object", "null"]}
                },
                required: ["email"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response("Magic link sent", OpenAPI.status_response_schema)
            }
          }
        }
      ) do |ctx|
        sender = config[:send_magic_link]
        link_base_url = ctx.context.base_url
        link_base_url = ctx.context.token_link_base_url if sender.respond_to?(:call)
        body = normalize_hash(ctx.body)
        email = body[:email].to_s.downcase
        raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES["INVALID_EMAIL"]) unless Routes::EMAIL_PATTERN.match?(email)

        token = magic_link_token(email, config)
        stored_token = store_magic_link_token(token, config)
        ctx.context.internal_adapter.create_verification_value(
          identifier: stored_token,
          value: JSON.generate({"email" => email, "name" => body[:name], "attempt" => 0}),
          expiresAt: Time.now + (config[:expires_in] || 60 * 5).to_i
        )

        link = magic_link_url(link_base_url, token, body)
        data = {email: email, url: link, token: token}
        data[:metadata] = body[:metadata] if body.key?(:metadata)
        sender.call(data, ctx) if sender.respond_to?(:call)
        ctx.json({status: true})
      end
    end

    def magic_link_verify_endpoint(config)
      Endpoint.new(
        path: "/magic-link/verify",
        method: "GET",
        metadata: {
          openapi: {
            operationId: "magicLinkVerify",
            description: "Verify a magic link token",
            parameters: [
              {
                name: "token",
                in: "query",
                required: true,
                schema: {type: "string"}
              },
              {
                name: "callbackURL",
                in: "query",
                required: false,
                schema: {type: "string"}
              }
            ],
            responses: {
              "200" => OpenAPI.json_response(
                "Magic link verified",
                OpenAPI.object_schema(
                  {
                    token: {type: "string"},
                    user: {type: "object", "$ref": "#/components/schemas/User"},
                    session: {type: "object", "$ref": "#/components/schemas/Session"}
                  },
                  required: ["token", "user", "session"]
                )
              ),
              "302" => {description: "Redirects to callback URL when callbackURL is provided"}
            }
          }
        }
      ) do |ctx|
        query = normalize_hash(ctx.query)
        token = query[:token].to_s
        callback_url = query[:callback_url] || "/"
        error_callback_url = query[:error_callback_url] || callback_url
        new_user_callback_url = query[:new_user_callback_url] || callback_url

        validate_magic_link_callback!(ctx, callback_url, "callbackURL")
        validate_magic_link_callback!(ctx, error_callback_url, "errorCallbackURL")
        validate_magic_link_callback!(ctx, new_user_callback_url, "newUserCallbackURL")

        redirect_with_error = lambda do |error|
          raise ctx.redirect(magic_link_error_url(error_callback_url, error))
        end

        stored_token = store_magic_link_token(token, config)
        verification = ctx.context.internal_adapter.find_verification_value(stored_token)
        redirect_with_error.call("INVALID_TOKEN") unless verification

        if Routes.expired_time?(verification["expiresAt"])
          ctx.context.internal_adapter.delete_verification_value(verification["id"])
          redirect_with_error.call("EXPIRED_TOKEN")
        end

        payload = JSON.parse(verification["value"])
        email = payload.fetch("email").to_s.downcase
        name = payload["name"]
        attempt = payload["attempt"].to_i
        if magic_link_attempts_exceeded?(attempt, config)
          ctx.context.internal_adapter.delete_verification_value(verification["id"])
          redirect_with_error.call("ATTEMPTS_EXCEEDED")
        end
        ctx.context.internal_adapter.update_verification_value(
          verification["id"],
          value: JSON.generate(payload.merge("attempt" => attempt + 1))
        )
        found = ctx.context.internal_adapter.find_user_by_email(email)
        user = found && found[:user]
        new_user = false

        unless user
          redirect_with_error.call("new_user_signup_disabled") if config[:disable_sign_up]

          user = ctx.context.internal_adapter.create_user(
            email: email,
            emailVerified: true,
            name: name || "",
            context: ctx
          )
          new_user = true
          redirect_with_error.call("failed_to_create_user") unless user
        end

        unless user["emailVerified"]
          user = ctx.context.internal_adapter.update_user(user["id"], emailVerified: true)
        end

        session = ctx.context.internal_adapter.create_session(user["id"])
        redirect_with_error.call("failed_to_create_session") unless session

        Cookies.set_session_cookie(ctx, {session: session, user: user})
        unless query.key?(:callback_url)
          next ctx.json({
            token: session["token"],
            user: Schema.parse_output(ctx.context.options, "user", user),
            session: Schema.parse_output(ctx.context.options, "session", session)
          })
        end

        raise ctx.redirect(new_user ? new_user_callback_url : callback_url)
      rescue JSON::ParserError, KeyError
        raise ctx.redirect(magic_link_error_url(error_callback_url || "/", "INVALID_TOKEN"))
      end
    end

    def magic_link_token(email, config)
      generator = config[:generate_token]
      return generator.call(email) if generator.respond_to?(:call)

      Array.new(32) { [*"a".."z", *"A".."Z"].sample }.join
    end

    def magic_link_attempts_exceeded?(attempt, config)
      allowed = config[:allowed_attempts]
      return false if allowed.respond_to?(:infinite?) && allowed.infinite?

      attempt >= allowed.to_i
    end

    def store_magic_link_token(token, config)
      storage = config[:store_token]
      return Crypto.sha256(token, encoding: :base64url) if storage.to_s == "hashed"

      if storage.is_a?(Hash) && %w[custom-hasher custom_hasher].include?(storage[:type].to_s)
        hasher = storage[:hash]
        return hasher.call(token) if hasher.respond_to?(:call)
      end

      token
    end

    def magic_link_url(base_url, token, body)
      params = {
        token: token,
        callbackURL: body[:callback_url] || "/"
      }
      params[:newUserCallbackURL] = body[:new_user_callback_url] if body[:new_user_callback_url]
      params[:errorCallbackURL] = body[:error_callback_url] if body[:error_callback_url]
      "#{base_url}/magic-link/verify?#{URI.encode_www_form(params)}"
    end

    def validate_magic_link_callback!(ctx, value, label)
      return if value.nil? || value.to_s.empty?
      return if ctx.context.trusted_origin?(value.to_s, allow_relative_paths: true)

      raise APIError.new("FORBIDDEN", message: "Invalid #{label}")
    end

    def magic_link_error_url(url, error)
      uri = URI.parse(url.to_s.empty? ? "/" : url.to_s)
      query = URI.decode_www_form(uri.query.to_s)
      query << ["error", error]
      uri.query = URI.encode_www_form(query)
      uri.to_s
    rescue URI::InvalidURIError
      "/?error=#{URI.encode_www_form_component(error)}"
    end
  end
end
