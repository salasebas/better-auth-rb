# frozen_string_literal: true

require "uri"
require "securerandom"

module BetterAuth
  module Routes
    EMAIL_PATTERN = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

    def self.sign_up_email
      Endpoint.new(
        path: "/sign-up/email",
        method: "POST",
        body_schema: request_body_schema(
          required_strings: %w[name email],
          required_nonempty_strings: %w[password]
        ),
        metadata: {
          allowed_media_types: [
            "application/x-www-form-urlencoded",
            "application/json"
          ],
          openapi: {
            operationId: "signUpWithEmailAndPassword",
            description: "Sign up a user using email and password",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  name: {type: "string", description: "The name of the user"},
                  email: {type: "string", description: "The email of the user"},
                  password: {type: "string", description: "The password of the user"},
                  image: {type: "string", description: "The profile image URL of the user"},
                  callbackURL: {type: "string", description: "The URL to use for email verification callback"},
                  rememberMe: {type: "boolean", description: "If this is false, the session will not be remembered. Default is `true`."}
                },
                required: ["name", "email", "password"]
              ),
              required: false
            ),
            responses: {
              "200" => OpenAPI.json_response(
                "Successfully created user",
                OpenAPI.object_schema(
                  {
                    token: {type: "string", nullable: true, description: "Authentication token for the session"},
                    user: {type: "object", "$ref": "#/components/schemas/User"}
                  },
                  required: ["user"]
                )
              ),
              "422" => OpenAPI.error_response("Unprocessable Entity. User already exists or failed to create user.")
            }
          }
        }
      ) do |ctx|
        options = ctx.context.options
        email_config = options.email_and_password
        if email_config[:enabled] != true || email_config[:disable_sign_up]
          raise APIError.new("BAD_REQUEST", code: "EMAIL_PASSWORD_SIGN_UP_DISABLED", message: BASE_ERROR_CODES["EMAIL_PASSWORD_SIGN_UP_DISABLED"])
        end
        preflight_sign_up_token_link!(ctx)

        body = normalize_hash(ctx.body)
        name = body["name"].to_s
        email = body["email"].to_s
        password = body["password"]
        image = body["image"]
        callback_url = body["callbackURL"] || body["callbackUrl"] || body["callback_url"]
        remember_me = body.key?("rememberMe") ? body["rememberMe"] : body["remember_me"]

        validate_auth_callback_url!(ctx.context, callback_url, "callbackURL")
        validate_sign_up_input!(email, password, email_config)

        ctx.context.adapter.transaction do
          existing = ctx.context.internal_adapter.find_user_by_email(email)
          if existing
            if email_config[:require_email_verification]
              hash_password(ctx, password)
              call_existing_sign_up_callback(ctx, email_config, existing)
              synthetic_user = synthetic_sign_up_user(ctx, body, email, name, image)
              next ctx.json({token: nil, user: Schema.parse_output(options, "user", synthetic_user)})
            end

            raise APIError.new(
              "UNPROCESSABLE_ENTITY",
              message: BASE_ERROR_CODES["USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL"]
            )
          end

          hashed_password = hash_password(ctx, password)
          created_user = create_sign_up_user(ctx, body, email, name, image)
          raise APIError.new("UNPROCESSABLE_ENTITY", message: BASE_ERROR_CODES["FAILED_TO_CREATE_USER"]) unless created_user

          ctx.context.internal_adapter.link_account(
            userId: created_user["id"],
            providerId: "credential",
            accountId: created_user["id"],
            password: hashed_password
          )

          send_sign_up_verification_email(ctx, created_user, callback_url)

          if email_config[:auto_sign_in] == false || email_config[:require_email_verification]
            next ctx.json({token: nil, user: Schema.parse_output(options, "user", created_user)})
          end

          dont_remember_me = remember_me == false || remember_me.to_s == "false"
          session = ctx.context.internal_adapter.create_session(
            created_user["id"],
            dont_remember_me,
            session_overrides(ctx),
            true,
            ctx
          )
          raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES["FAILED_TO_CREATE_SESSION"]) unless session

          Cookies.set_session_cookie(ctx, {session: session, user: created_user}, dont_remember_me)
          ctx.json({token: session["token"], user: Schema.parse_output(options, "user", created_user)})
        end
      end
    end

    def self.validate_sign_up_input!(email, password, email_config)
      unless EMAIL_PATTERN.match?(email)
        raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES["INVALID_EMAIL"])
      end

      unless password.is_a?(String) && !password.empty?
        raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES["INVALID_PASSWORD"])
      end

      if password.length < email_config[:min_password_length].to_i
        raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES["PASSWORD_TOO_SHORT"])
      end

      if password.length > email_config[:max_password_length].to_i
        raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES["PASSWORD_TOO_LONG"])
      end
    end

    def self.validate_auth_callback_url!(context, value, label)
      return if value.nil? || value.to_s.empty?
      return if context.trusted_origin?(value.to_s, allow_relative_paths: true)

      raise APIError.new("FORBIDDEN", message: "Invalid #{label}")
    end

    def self.create_sign_up_user(ctx, body, email, name, image)
      reserved = %w[email password name image callbackURL callbackUrl callback_url rememberMe remember_me]
      additional = parse_declared_input(ctx, "user", body.except(*reserved), allowed_base: [])
      ctx.context.internal_adapter.create_user(
        additional.merge(
          "email" => email.downcase,
          "name" => name,
          "image" => image,
          "emailVerified" => false
        ),
        context: ctx
      )
    rescue APIError
      raise
    rescue
      raise APIError.new("UNPROCESSABLE_ENTITY", message: BASE_ERROR_CODES["FAILED_TO_CREATE_USER"])
    end

    def self.call_existing_sign_up_callback(ctx, email_config, existing)
      callback = email_config[:on_existing_user_sign_up]
      return unless callback.respond_to?(:call)

      user = existing[:user] || existing["user"] || existing
      data = {user: user}
      if callback.arity == 1
        callback.call(data)
      else
        callback.call(data, ctx.request)
      end
    end

    def self.synthetic_sign_up_user(ctx, body, email, name, image)
      now = Time.now
      core_fields = {
        "id" => SecureRandom.hex(16),
        "name" => name,
        "email" => email.to_s.downcase,
        "emailVerified" => false,
        "image" => image,
        "createdAt" => now,
        "updatedAt" => now
      }
      reserved = %w[email password name image callbackURL callbackUrl callback_url rememberMe remember_me]
      additional = synthetic_additional_user_fields(ctx, body.except(*reserved))
      custom = ctx.context.options.email_and_password[:custom_synthetic_user]
      return core_fields.merge(additional) unless custom.respond_to?(:call)

      value = {
        core_fields: core_fields.except("id"),
        coreFields: core_fields.except("id"),
        additional_fields: additional,
        additionalFields: additional,
        id: core_fields["id"]
      }
      stringify_synthetic_user(custom.call(value))
    end

    def self.synthetic_additional_user_fields(ctx, data)
      additional = parse_declared_input(ctx, "user", data, allowed_base: [])
      configured = ctx.context.options.user[:additional_fields] || {}
      configured.each do |field, attributes|
        storage_field = Schema.storage_key(field)
        next if additional.key?(storage_field)

        field_attributes = normalize_hash(attributes || {})
        next unless field_attributes.key?("defaultValue") || field_attributes.key?("default_value")

        default = field_attributes.key?("defaultValue") ? field_attributes["defaultValue"] : field_attributes["default_value"]
        additional[storage_field] = resolve_default(default)
      end
      additional
    end

    def self.resolve_default(value)
      value.respond_to?(:call) ? value.call : value
    end

    def self.stringify_synthetic_user(value)
      return value.each_with_object({}) { |(key, object_value), result| result[Schema.storage_key(key)] = object_value } if value.is_a?(Hash)

      {}
    end

    def self.send_sign_up_verification_email(ctx, user, callback_url)
      verification = ctx.context.options.email_verification
      password_config = ctx.context.options.email_and_password
      send_on_sign_up = verification.key?(:send_on_sign_up) ? verification[:send_on_sign_up] : password_config[:require_email_verification]
      return unless send_on_sign_up

      sender = verification[:send_verification_email]
      return unless sender.respond_to?(:call)

      token = Crypto.sign_jwt(
        {"email" => user["email"].to_s.downcase},
        ctx.context.secret,
        expires_in: verification[:expires_in] || 3600
      )
      callback = URI.encode_www_form_component(callback_url || "/")
      url = "#{ctx.context.token_link_base_url}/verify-email?token=#{URI.encode_www_form_component(token)}&callbackURL=#{callback}"
      sender.call({user: user, url: url, token: token}, ctx.request)
    end

    def self.preflight_sign_up_token_link!(ctx)
      verification = ctx.context.options.email_verification
      password_config = ctx.context.options.email_and_password
      send_on_sign_up = verification.key?(:send_on_sign_up) ? verification[:send_on_sign_up] : password_config[:require_email_verification]
      ctx.context.token_link_base_url if send_on_sign_up && verification[:send_verification_email].respond_to?(:call)
    end

    def self.session_overrides(ctx)
      {
        ipAddress: RequestIP.client_ip(ctx, ctx.context.options).to_s,
        userAgent: ctx.headers["user-agent"].to_s
      }
    end

    def self.normalize_hash(value)
      value.each_with_object({}) do |(key, object_value), result|
        result[Schema.storage_key(key)] = object_value
      end
    end
  end
end
