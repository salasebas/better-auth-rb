# frozen_string_literal: true

require "uri"

module BetterAuth
  module Plugins
    USERNAME_ERROR_CODES = {
      "INVALID_USERNAME_OR_PASSWORD" => "Invalid username or password",
      "EMAIL_NOT_VERIFIED" => "Email not verified",
      "UNEXPECTED_ERROR" => "Unexpected error",
      "USERNAME_IS_ALREADY_TAKEN" => "Username is already taken. Please try another.",
      "USERNAME_TOO_SHORT" => "Username is too short",
      "USERNAME_TOO_LONG" => "Username is too long",
      "INVALID_USERNAME" => "Username is invalid",
      "INVALID_DISPLAY_USERNAME" => "Display username is invalid"
    }.freeze

    module_function

    def username(options = {})
      config = normalize_hash(options)

      Plugin.new(
        id: "username",
        init: ->(_context) { {options: {database_hooks: username_database_hooks(config)}} },
        endpoints: {
          sign_in_username: sign_in_username_endpoint(config),
          is_username_available: is_username_available_endpoint(config)
        },
        schema: username_schema(config),
        hooks: {
          before: [
            {
              matcher: ->(ctx) { username_mutation_path?(ctx.path) },
              handler: ->(ctx) { validate_username_mutation!(ctx, config) }
            },
            {
              matcher: ->(ctx) { username_mutation_path?(ctx.path) },
              handler: ->(ctx) { mirror_username_fields!(ctx) }
            }
          ]
        },
        error_codes: USERNAME_ERROR_CODES,
        options: config
      )
    end

    def sign_in_username_endpoint(config)
      Endpoint.new(
        path: "/sign-in/username",
        method: "POST",
        metadata: {
          allowed_media_types: [
            "application/x-www-form-urlencoded",
            "application/json"
          ],
          openapi: {
            operationId: "signInUsername",
            description: "Sign in with username and password",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  username: {type: "string"},
                  password: {type: "string"},
                  callbackURL: {type: ["string", "null"]},
                  rememberMe: {type: ["boolean", "null"]}
                },
                required: ["username", "password"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response(
                "Signed in",
                OpenAPI.object_schema(
                  {
                    redirect: {type: "boolean"},
                    token: {type: "string"},
                    url: {type: ["string", "null"]},
                    user: {type: "object", "$ref": "#/components/schemas/User"}
                  },
                  required: ["redirect", "token", "user"]
                )
              )
            }
          }
        }
      ) do |ctx|
        body = normalize_hash(ctx.body)
        raw_username = body[:username].to_s
        password = body[:password].to_s
        callback_url = body[:callback_url] || body[:callbackURL]
        remember_me = body.key?(:remember_me) ? body[:remember_me] : body[:rememberMe]
        Routes.preflight_sign_in_token_link!(ctx)

        if raw_username.empty? || password.empty?
          raise APIError.new("UNAUTHORIZED", message: USERNAME_ERROR_CODES["INVALID_USERNAME_OR_PASSWORD"])
        end

        username = username_for_sign_in_validation(raw_username, config)
        validate_username!(username, config, status: "UNPROCESSABLE_ENTITY")

        user = ctx.context.adapter.find_one(
          model: "user",
          where: [{field: "username", value: normalize_username(raw_username, config)}]
        )
        unless user
          Routes.hash_password(ctx, password)
          raise APIError.new("UNAUTHORIZED", message: USERNAME_ERROR_CODES["INVALID_USERNAME_OR_PASSWORD"])
        end

        account = ctx.context.adapter.find_one(
          model: "account",
          where: [
            {field: "userId", value: user["id"]},
            {field: "providerId", value: "credential"}
          ]
        )
        current_password = account && account["password"]
        email_config = ctx.context.options.email_and_password
        unless current_password && Routes.verify_password_value(ctx, password, current_password)
          Routes.hash_password(ctx, password) unless current_password
          raise APIError.new("UNAUTHORIZED", message: USERNAME_ERROR_CODES["INVALID_USERNAME_OR_PASSWORD"])
        end

        if email_config[:require_email_verification] && !user["emailVerified"]
          Routes.send_sign_in_verification_email(ctx, user, callback_url)
          raise APIError.new("FORBIDDEN", message: USERNAME_ERROR_CODES["EMAIL_NOT_VERIFIED"])
        end

        dont_remember_me = remember_me == false || remember_me.to_s == "false"
        session = ctx.context.internal_adapter.create_session(
          user["id"],
          dont_remember_me,
          Routes.session_overrides(ctx),
          true
        )
        raise APIError.new("INTERNAL_SERVER_ERROR", message: BASE_ERROR_CODES["FAILED_TO_CREATE_SESSION"]) unless session

        Cookies.set_session_cookie(ctx, {session: session, user: user}, dont_remember_me)
        ctx.set_header("location", callback_url) if callback_url
        ctx.json({
          redirect: !callback_url.nil?,
          token: session["token"],
          url: callback_url,
          user: Schema.parse_output(ctx.context.options, "user", user)
        })
      end
    end

    def is_username_available_endpoint(config)
      Endpoint.new(
        path: "/is-username-available",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "isUsernameAvailable",
            description: "Check whether a username is available",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  username: {type: "string"}
                },
                required: ["username"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response(
                "Username availability",
                OpenAPI.object_schema(
                  {
                    available: {type: "boolean"}
                  },
                  required: ["available"]
                )
              )
            }
          }
        }
      ) do |ctx|
        body = normalize_hash(ctx.body)
        username = body[:username].to_s
        raise APIError.new("UNPROCESSABLE_ENTITY", message: USERNAME_ERROR_CODES["INVALID_USERNAME"]) if username.empty?

        validate_username!(username, config, status: "UNPROCESSABLE_ENTITY")
        user = ctx.context.adapter.find_one(
          model: "user",
          where: [{field: "username", value: normalize_username(username, config)}]
        )
        ctx.json({available: user.nil?})
      end
    end

    def username_schema(config)
      {
        user: {
          fields: {
            username: {
              type: "string",
              required: false,
              sortable: true,
              unique: true,
              returned: true,
              field_name: "username"
            },
            displayUsername: {
              type: "string",
              required: false,
              field_name: "display_username"
            }
          }
        }
      }
    end

    def username_database_hooks(config)
      before_hook = lambda do |user, endpoint_context|
        data = user.dup
        raw_username = data["username"]
        raw_display_username = data["displayUsername"]
        if raw_username.is_a?(String) && !raw_username.empty?
          unless endpoint_context && username_mutation_path?(endpoint_context.path)
            username = username_for_validation(raw_username, config)
            validate_username!(username, config, status: "BAD_REQUEST")
            adapter = endpoint_context&.context&.adapter
            if adapter
              existing = adapter.find_one(model: "user", where: [{field: "username", value: normalize_username(username, config)}])
              current_user_id = endpoint_context&.context&.current_session&.dig(:user, "id")
              if existing && existing["id"] != current_user_id
                raise APIError.new("BAD_REQUEST", code: "USERNAME_IS_ALREADY_TAKEN", message: USERNAME_ERROR_CODES["USERNAME_IS_ALREADY_TAKEN"])
              end
            end
          end
          data["username"] = normalize_username(raw_username, config)
          data["displayUsername"] = raw_username unless raw_display_username.is_a?(String) && !raw_display_username.empty?
        end
        if data["displayUsername"].is_a?(String) && !data["displayUsername"].empty?
          display_username = if validation_order(config, :display_username) == "post-normalization"
            normalize_display_username(data["displayUsername"], config)
          else
            data["displayUsername"]
          end
          validator = config[:display_username_validator]
          unless !validator.respond_to?(:call) || validator.call(display_username)
            raise APIError.new("BAD_REQUEST", code: "INVALID_DISPLAY_USERNAME", message: USERNAME_ERROR_CODES["INVALID_DISPLAY_USERNAME"])
          end
          data["displayUsername"] = normalize_display_username(data["displayUsername"], config)
        end
        {data: data}
      end

      {
        user: {
          create: {before: before_hook},
          update: {before: before_hook}
        }
      }
    end

    def validate_username_mutation!(ctx, config)
      body = normalize_hash(ctx.body)
      raw_username = body.key?(:username) ? body[:username] : nil
      if raw_username.nil? && present?(body[:display_username])
        begin
          validate_username!(username_for_validation(body[:display_username], config), config, status: "BAD_REQUEST")
          body[:username] = body[:display_username]
          raw_username = body[:username]
        rescue APIError
          # A display-only value that cannot be a username remains display-only.
        end
      end
      username = if raw_username.is_a?(String) && validation_order(config, :username) == "post-normalization"
        normalize_username(raw_username, config)
      else
        raw_username
      end

      if username.is_a?(String)
        validate_username!(username, config, status: "BAD_REQUEST")
        existing = ctx.context.adapter.find_one(model: "user", where: [{field: "username", value: normalize_username(username, config)}])
        current = (ctx.path == "/update-user") ? Routes.current_session(ctx, allow_nil: true) : nil
        same_user = existing && current && existing["id"] == current[:session]["userId"]

        if existing && ctx.path == "/sign-up/email"
          raise APIError.new("UNPROCESSABLE_ENTITY", code: "USERNAME_IS_ALREADY_TAKEN", message: USERNAME_ERROR_CODES["USERNAME_IS_ALREADY_TAKEN"])
        end

        if existing && ctx.path == "/update-user" && !same_user
          raise APIError.new("BAD_REQUEST", code: "USERNAME_IS_ALREADY_TAKEN", message: USERNAME_ERROR_CODES["USERNAME_IS_ALREADY_TAKEN"])
        end
      end

      raw_display_username = body.key?(:display_username) ? body[:display_username] : nil
      display_username = if raw_display_username.is_a?(String) && validation_order(config, :display_username) == "post-normalization"
        normalize_display_username(raw_display_username, config)
      else
        raw_display_username
      end

      if display_username.is_a?(String)
        validator = config[:display_username_validator]
        unless !validator.respond_to?(:call) || validator.call(display_username)
          raise APIError.new("BAD_REQUEST", code: "INVALID_DISPLAY_USERNAME", message: USERNAME_ERROR_CODES["INVALID_DISPLAY_USERNAME"])
        end
      end
      ctx.body = body
      nil
    end

    def mirror_username_fields!(ctx)
      body = normalize_hash(ctx.body)
      body[:display_username] = body[:username] if present?(body[:username]) && !present?(body[:display_username])
      ctx.body = body
      nil
    end

    def validate_username!(username, config, status:)
      if username.length < min_username_length(config)
        raise APIError.new(status, code: "USERNAME_TOO_SHORT", message: USERNAME_ERROR_CODES["USERNAME_TOO_SHORT"])
      end

      if username.length > max_username_length(config)
        raise APIError.new(status, code: "USERNAME_TOO_LONG", message: USERNAME_ERROR_CODES["USERNAME_TOO_LONG"])
      end

      validator = config[:username_validator]
      valid = validator.respond_to?(:call) ? validator.call(username) : default_username_valid?(username)
      raise APIError.new(status, code: "INVALID_USERNAME", message: USERNAME_ERROR_CODES["INVALID_USERNAME"]) unless valid
    end

    def username_for_validation(username, config)
      (validation_order(config, :username) == "post-normalization") ? normalize_username(username, config) : username
    end

    def username_for_sign_in_validation(username, config)
      (validation_order(config, :username) == "pre-normalization") ? normalize_username(username, config) : username
    end

    def normalize_username(username, config)
      normalizer = config[:username_normalization]
      return username if normalizer == false
      return normalizer.call(username) if normalizer.respond_to?(:call)

      username.downcase
    end

    def normalize_display_username(display_username, config)
      normalizer = config[:display_username_normalization]
      normalizer.respond_to?(:call) ? normalizer.call(display_username) : display_username
    end

    def validation_order(config, field)
      order = config[:validation_order] || {}
      order[field] || "pre-normalization"
    end

    def username_mutation_path?(path)
      path == "/sign-up/email" || path == "/update-user"
    end

    def min_username_length(config)
      (config[:min_username_length] || 3).to_i
    end

    def max_username_length(config)
      (config[:max_username_length] || 30).to_i
    end

    def default_username_valid?(username)
      username.match?(/\A[a-zA-Z0-9_.]+\z/)
    end

    def present?(value)
      !value.nil? && value != false && !value.to_s.empty?
    end
  end
end
