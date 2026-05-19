# frozen_string_literal: true

require "securerandom"

module BetterAuth
  module Plugins
    ANONYMOUS_ERROR_CODES = {
      "INVALID_EMAIL_FORMAT" => "Email was not generated in a valid format",
      "FAILED_TO_CREATE_USER" => "Failed to create user",
      "COULD_NOT_CREATE_SESSION" => "Could not create session",
      "ANONYMOUS_USERS_CANNOT_SIGN_IN_AGAIN_ANONYMOUSLY" => "Anonymous users cannot sign in again anonymously",
      "FAILED_TO_DELETE_ANONYMOUS_USER" => "Failed to delete anonymous user",
      "USER_IS_NOT_ANONYMOUS" => "User is not anonymous",
      "DELETE_ANONYMOUS_USER_DISABLED" => "Deleting anonymous users is disabled"
    }.freeze

    module_function

    def anonymous(options = {})
      config = normalize_hash(options)

      Plugin.new(
        id: "anonymous",
        endpoints: {
          sign_in_anonymous: sign_in_anonymous_endpoint(config),
          delete_anonymous_user: delete_anonymous_user_endpoint(config)
        },
        hooks: {
          after: [
            {
              matcher: ->(ctx) { anonymous_link_path?(ctx.path) },
              handler: ->(ctx) { link_anonymous_user(ctx, config) }
            }
          ]
        },
        schema: anonymous_schema(config),
        error_codes: ANONYMOUS_ERROR_CODES,
        options: config
      )
    end

    def sign_in_anonymous_endpoint(config)
      Endpoint.new(
        path: "/sign-in/anonymous",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "signInAnonymous",
            description: "Sign in anonymously",
            requestBody: OpenAPI.empty_request_body,
            responses: {
              "200" => OpenAPI.json_response(
                "Anonymous session created",
                OpenAPI.object_schema(
                  {
                    token: {type: "string"},
                    user: {type: "object", "$ref": "#/components/schemas/User"}
                  },
                  required: ["token", "user"]
                )
              )
            }
          }
        }
      ) do |ctx|
        existing_session = Session.find_current(ctx, disable_refresh: true)
        if existing_session&.dig(:user, "isAnonymous")
          raise APIError.new("BAD_REQUEST", message: ANONYMOUS_ERROR_CODES["ANONYMOUS_USERS_CANNOT_SIGN_IN_AGAIN_ANONYMOUSLY"])
        end

        email = anonymous_email(config)
        name = anonymous_name(ctx, config)
        user = ctx.context.internal_adapter.create_user(
          email: email,
          emailVerified: false,
          isAnonymous: true,
          name: name,
          createdAt: Time.now,
          updatedAt: Time.now,
          context: ctx
        )
        raise APIError.new("INTERNAL_SERVER_ERROR", message: ANONYMOUS_ERROR_CODES["FAILED_TO_CREATE_USER"]) unless user

        session = ctx.context.internal_adapter.create_session(user["id"])
        raise APIError.new("BAD_REQUEST", message: ANONYMOUS_ERROR_CODES["COULD_NOT_CREATE_SESSION"]) unless session

        Cookies.set_session_cookie(ctx, {session: session, user: user})
        ctx.json({token: session["token"], user: Schema.parse_output(ctx.context.options, "user", user)})
      end
    end

    def delete_anonymous_user_endpoint(config)
      Endpoint.new(
        path: "/delete-anonymous-user",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "deleteAnonymousUser",
            description: "Delete the current anonymous user",
            requestBody: OpenAPI.empty_request_body,
            responses: {
              "200" => OpenAPI.json_response("Anonymous user deleted", OpenAPI.success_response_schema)
            }
          }
        }
      ) do |ctx|
        session = Routes.current_session(ctx, sensitive: true)

        if config[:disable_delete_anonymous_user]
          raise APIError.new("BAD_REQUEST", message: ANONYMOUS_ERROR_CODES["DELETE_ANONYMOUS_USER_DISABLED"])
        end

        unless session[:user]["isAnonymous"]
          raise APIError.new("FORBIDDEN", message: ANONYMOUS_ERROR_CODES["USER_IS_NOT_ANONYMOUS"])
        end

        begin
          ctx.context.internal_adapter.delete_user(session[:user]["id"])
        rescue
          raise APIError.new("INTERNAL_SERVER_ERROR", message: ANONYMOUS_ERROR_CODES["FAILED_TO_DELETE_ANONYMOUS_USER"])
        end

        Cookies.delete_session_cookie(ctx)
        ctx.json({success: true})
      end
    end

    def anonymous_schema(config)
      field_name = anonymous_schema_field_name(config) || "is_anonymous"
      {
        user: {
          fields: {
            isAnonymous: {
              type: "boolean",
              required: false,
              input: false,
              default_value: false,
              field_name: field_name
            }
          }
        }
      }
    end

    def anonymous_email(config)
      generator = config[:generate_random_email]
      email = generator.call if generator.respond_to?(:call)
      if email && email != ""
        unless email.is_a?(String) && !email.empty? && Routes::EMAIL_PATTERN.match?(email)
          raise APIError.new("BAD_REQUEST", message: ANONYMOUS_ERROR_CODES["INVALID_EMAIL_FORMAT"])
        end
        return email
      end

      id = SecureRandom.hex(16)
      domain = config[:email_domain_name]
      domain ? "temp-#{id}@#{domain}" : "temp@#{id}.com"
    end

    def anonymous_name(ctx, config)
      generator = config[:generate_name]
      name = generator.call(ctx) if generator.respond_to?(:call)
      return name if present_string?(name)

      "Anonymous"
    end

    def link_anonymous_user(ctx, config)
      set_cookie = ctx.response_headers["set-cookie"].to_s
      return if set_cookie.empty?
      return unless set_cookie_value(set_cookie, ctx.context.auth_cookies[:session_token].name)

      anonymous_session = Session.find_current(ctx, disable_refresh: true)
      return unless anonymous_session&.dig(:user, "isAnonymous")

      new_session = ctx.context.new_session
      return unless new_session && new_session[:user] && new_session[:session]

      on_link_account = config[:on_link_account]
      if on_link_account.respond_to?(:call)
        on_link_account.call(
          anonymous_user: anonymous_session,
          new_user: new_session,
          ctx: ctx
        )
      end

      new_user = new_session[:user]
      return if config[:disable_delete_anonymous_user]
      return if new_user["id"] == anonymous_session[:user]["id"]
      return if new_user["isAnonymous"]

      ctx.context.internal_adapter.delete_user(anonymous_session[:user]["id"])
      nil
    end

    def set_cookie_value(set_cookie, name)
      set_cookie.to_s.lines.each do |line|
        cookie_pair = line.split(";", 2).first.to_s.strip
        cookie_name, value = cookie_pair.split("=", 2)
        return value if cookie_name == name && !value.nil?
      end

      nil
    end

    def anonymous_link_path?(path)
      path.to_s.start_with?(
        "/sign-in",
        "/sign-up",
        "/callback",
        "/oauth2/callback",
        "/magic-link/verify",
        "/email-otp/verify-email",
        "/one-tap/callback",
        "/passkey/verify-authentication",
        "/phone-number/verify"
      )
    end

    def anonymous_schema_field_name(config)
      fields = config.dig(:schema, :user, :fields) || {}
      mapping = fields[:is_anonymous] || fields[:isAnonymous] || fields["isAnonymous"]
      return mapping if mapping.is_a?(String)
      return mapping[:field_name] || mapping[:fieldName] if mapping.is_a?(Hash)

      nil
    end

    def present_string?(value)
      value.is_a?(String) && !value.empty?
    end
  end
end
