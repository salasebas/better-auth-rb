# frozen_string_literal: true

require "uri"

module BetterAuth
  module Routes
    def self.sign_in_email
      Endpoint.new(
        path: "/sign-in/email",
        method: "POST",
        body_schema: request_body_schema(required_strings: %w[email password]),
        metadata: {
          allowed_media_types: [
            "application/x-www-form-urlencoded",
            "application/json"
          ],
          openapi: {
            operationId: "signInEmail",
            description: "Sign in with email and password",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  email: {type: "string", description: "Email of the user"},
                  password: {type: "string", description: "Password of the user"},
                  callbackURL: {type: ["string", "null"], description: "Callback URL to use as a redirect for email verification"},
                  rememberMe: {type: ["boolean", "null"], default: true, description: "If this is false, the session will not be remembered. Default is `true`."}
                },
                required: ["email", "password"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response(
                "Success - Returns either session details or redirect URL",
                OpenAPI.session_response_schema(description: "Session response when idToken is provided", nullable_url: true)
              )
            }
          }
        }
      ) do |ctx|
        options = ctx.context.options
        email_config = options.email_and_password
        if email_config[:enabled] != true
          raise APIError.new("BAD_REQUEST", code: "EMAIL_PASSWORD_DISABLED", message: BASE_ERROR_CODES["EMAIL_PASSWORD_DISABLED"])
        end

        body = normalize_hash(ctx.body)
        email = body["email"].to_s
        password = body["password"].to_s
        callback_url = body["callbackURL"] || body["callbackUrl"] || body["callback_url"]
        remember_me = body.key?("rememberMe") ? body["rememberMe"] : body["remember_me"]

        validate_auth_callback_url!(ctx.context, callback_url, "callbackURL")
        preflight_sign_in_token_link!(ctx)

        unless EMAIL_PATTERN.match?(email)
          raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES["INVALID_EMAIL"])
        end

        found = ctx.context.internal_adapter.find_user_by_email(email, include_accounts: true)
        unless found
          hash_password(ctx, password)
          raise APIError.new("UNAUTHORIZED", message: BASE_ERROR_CODES["INVALID_EMAIL_OR_PASSWORD"])
        end

        user = found[:user] || found["user"]
        accounts = found[:accounts] || found["accounts"] || []
        credential_account = accounts.find { |account| account["providerId"] == "credential" || account[:providerId] == "credential" }
        current_password = credential_account && (credential_account["password"] || credential_account[:password])
        unless current_password && verify_password_value(ctx, password, current_password)
          hash_password(ctx, password) unless current_password
          raise APIError.new("UNAUTHORIZED", message: BASE_ERROR_CODES["INVALID_EMAIL_OR_PASSWORD"])
        end

        if email_config[:require_email_verification] && !user["emailVerified"]
          send_sign_in_verification_email(ctx, user, callback_url)
          raise APIError.new("FORBIDDEN", message: BASE_ERROR_CODES["EMAIL_NOT_VERIFIED"])
        end

        dont_remember_me = remember_me == false || remember_me.to_s == "false"
        session = ctx.context.internal_adapter.create_session(
          user["id"],
          dont_remember_me,
          session_overrides(ctx),
          true,
          ctx
        )
        raise APIError.new("UNAUTHORIZED", message: BASE_ERROR_CODES["FAILED_TO_CREATE_SESSION"]) unless session

        Cookies.set_session_cookie(ctx, {session: session, user: user}, dont_remember_me)
        ctx.set_header("location", callback_url) if callback_url
        ctx.json({
          redirect: !!callback_url,
          token: session["token"],
          url: callback_url,
          user: Schema.parse_output(options, "user", user)
        })
      end
    end

    def self.send_sign_in_verification_email(ctx, user, callback_url)
      verification = ctx.context.options.email_verification
      sender = verification[:send_verification_email]
      return unless verification[:send_on_sign_in] && sender.respond_to?(:call)

      token = Crypto.sign_jwt(
        {"email" => user["email"].to_s.downcase},
        ctx.context.secret,
        expires_in: verification[:expires_in] || 3600
      )
      callback = URI.encode_www_form_component(callback_url || "/")
      url = "#{ctx.context.token_link_base_url}/verify-email?token=#{URI.encode_www_form_component(token)}&callbackURL=#{callback}"
      sender.call({user: user, url: url, token: token}, ctx.request)
    end

    def self.preflight_sign_in_token_link!(ctx)
      verification = ctx.context.options.email_verification
      password_config = ctx.context.options.email_and_password
      if password_config[:require_email_verification] && verification[:send_on_sign_in] && verification[:send_verification_email].respond_to?(:call)
        ctx.context.token_link_base_url
      end
    end
  end
end
