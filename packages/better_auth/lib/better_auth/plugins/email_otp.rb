# frozen_string_literal: true

module BetterAuth
  module Plugins
    EMAIL_OTP_ERROR_CODES = {
      "OTP_EXPIRED" => "OTP expired",
      "INVALID_OTP" => "Invalid OTP",
      "TOO_MANY_ATTEMPTS" => "Too many attempts"
    }.freeze

    module_function

    def email_otp(options = {})
      config = {
        expires_in: 5 * 60,
        otp_length: 6,
        store_otp: "plain",
        allowed_attempts: 3
      }.merge(normalize_hash(options))

      Plugin.new(
        id: "email-otp",
        init: email_otp_init(config),
        endpoints: {
          send_verification_otp: send_verification_otp_endpoint(config),
          create_verification_otp: create_verification_otp_endpoint(config),
          get_verification_otp: get_verification_otp_endpoint(config),
          check_verification_otp: check_verification_otp_endpoint(config),
          verify_email_otp: verify_email_otp_endpoint(config),
          sign_in_email_otp: sign_in_email_otp_endpoint(config),
          request_password_reset_email_otp: request_password_reset_email_otp_endpoint(config),
          reset_password_email_otp: reset_password_email_otp_endpoint(config),
          request_email_change_email_otp: request_email_change_email_otp_endpoint(config),
          change_email_email_otp: change_email_email_otp_endpoint(config)
        },
        hooks: {
          after: [
            {
              matcher: ->(ctx) { ctx.path.to_s.start_with?("/sign-up") && config[:send_verification_on_sign_up] && !config[:override_default_email_verification] },
              handler: ->(ctx) { email_otp_after_sign_up(ctx, config) }
            }
          ]
        },
        rate_limit: email_otp_rate_limits(config),
        error_codes: EMAIL_OTP_ERROR_CODES,
        options: config
      )
    end

    def email_otp_init(config)
      lambda do |context|
        next unless config[:override_default_email_verification]

        {
          options: {
            email_verification: {
              send_verification_email: lambda do |data, request = nil|
                user = fetch_value(data, :user) || data
                email = fetch_value(user, :email).to_s
                endpoint_context = Endpoint::Context.new(
                  path: "/send-verification-email",
                  method: "POST",
                  query: {},
                  body: {"email" => email, "type" => "email-verification"},
                  params: {},
                  headers: {},
                  context: context,
                  request: request
                )
                email_otp_send_verification(endpoint_context, config, email: email, type: "email-verification")
              end
            }
          }
        }
      end
    end

    def send_verification_otp_endpoint(config)
      Endpoint.new(
        path: "/email-otp/send-verification-otp",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "sendVerificationOTP",
            description: "Send an email verification OTP",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  email: {type: "string"},
                  type: {type: "string", enum: ["email-verification", "sign-in", "forget-password"]}
                },
                required: ["email", "type"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response("OTP sent", OpenAPI.success_response_schema)
            }
          }
        }
      ) do |ctx|
        body = normalize_hash(ctx.body)
        email = body[:email].to_s.downcase
        type = body[:type].to_s
        validate_email_otp_type!(type)
        validate_email_otp_email!(email)
        if type == "change-email"
          raise APIError.new("BAD_REQUEST", message: "Invalid OTP type")
        end

        sender = config[:send_verification_otp]
        unless sender.respond_to?(:call)
          raise APIError.new("BAD_REQUEST", message: "send email verification is not implemented")
        end

        email_otp_send_verification(ctx, config, email: email, type: type)
        ctx.json({success: true})
      end
    end

    def create_verification_otp_endpoint(config)
      Endpoint.new(method: "POST") do |ctx|
        body = normalize_hash(ctx.body)
        email = body[:email].to_s.downcase
        type = body[:type].to_s
        validate_email_otp_type!(type)

        otp = email_otp_generate(config, email: email, type: type, ctx: ctx)
        email_otp_store(ctx, config, email: email, type: type, otp: otp)
        otp
      end
    end

    def get_verification_otp_endpoint(config)
      Endpoint.new(
        path: "/email-otp/get-verification-otp",
        method: "GET",
        metadata: {
          openapi: {
            operationId: "getVerificationOTP",
            description: "Get a stored verification OTP when storage allows plaintext access",
            parameters: [
              {name: "email", in: "query", required: true, schema: {type: "string"}},
              {name: "type", in: "query", required: true, schema: {type: "string"}}
            ],
            responses: {
              "200" => OpenAPI.json_response(
                "Stored OTP",
                OpenAPI.object_schema(
                  {
                    otp: {type: ["string", "null"]}
                  }
                )
              )
            }
          }
        }
      ) do |ctx|
        query = normalize_hash(ctx.query)
        email = query[:email].to_s.downcase
        type = query[:type].to_s
        validate_email_otp_type!(type)
        verification = ctx.context.internal_adapter.find_verification_value(email_otp_identifier(email, type))
        next ctx.json({otp: nil}) unless verification && !Routes.expired_time?(verification["expiresAt"])

        stored_otp, = email_otp_split(verification["value"])
        case config[:store_otp].to_s
        when "hashed"
          raise APIError.new("BAD_REQUEST", message: "OTP is hashed, cannot return the plain text OTP")
        when "encrypted"
          next ctx.json({otp: Crypto.symmetric_decrypt(key: ctx.context.secret_config, data: stored_otp)})
        end

        storage = config[:store_otp]
        if storage.is_a?(Hash) && storage[:hash].respond_to?(:call)
          raise APIError.new("BAD_REQUEST", message: "OTP is hashed, cannot return the plain text OTP")
        elsif storage.is_a?(Hash) && storage[:decrypt].respond_to?(:call)
          next ctx.json({otp: storage[:decrypt].call(stored_otp)})
        end

        ctx.json({otp: stored_otp})
      end
    end

    def check_verification_otp_endpoint(config)
      Endpoint.new(
        path: "/email-otp/check-verification-otp",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "checkVerificationOTP",
            description: "Check an email verification OTP without consuming it",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  email: {type: "string"},
                  type: {type: "string"},
                  otp: {type: "string"}
                },
                required: ["email", "type", "otp"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response("OTP is valid", OpenAPI.success_response_schema)
            }
          }
        }
      ) do |ctx|
        body = normalize_hash(ctx.body)
        email = body[:email].to_s.downcase
        type = body[:type].to_s
        otp = body[:otp].to_s
        validate_email_otp_type!(type)
        validate_email_otp_email!(email)
        raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES["USER_NOT_FOUND"]) unless ctx.context.internal_adapter.find_user_by_email(email)

        email_otp_verify!(ctx, config, email: email, type: type, otp: otp, consume: false)
        ctx.json({success: true})
      end
    end

    def verify_email_otp_endpoint(config)
      Endpoint.new(
        path: "/email-otp/verify-email",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "verifyEmailOTP",
            description: "Verify an email address with an OTP",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  email: {type: "string"},
                  otp: {type: "string"}
                },
                required: ["email", "otp"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response(
                "Email verified",
                OpenAPI.object_schema(
                  {
                    status: {type: "boolean"},
                    token: {type: ["string", "null"]},
                    user: {type: "object", "$ref": "#/components/schemas/User"}
                  },
                  required: ["status", "user"]
                )
              )
            }
          }
        }
      ) do |ctx|
        body = normalize_hash(ctx.body)
        email = body[:email].to_s.downcase
        otp = body[:otp].to_s
        validate_email_otp_email!(email)

        email_otp_verify!(ctx, config, email: email, type: "email-verification", otp: otp)
        found = ctx.context.internal_adapter.find_user_by_email(email)
        raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES["USER_NOT_FOUND"]) unless found

        user = found[:user]
        call_email_verification_option(ctx, :before_email_verification, user)
        updated = ctx.context.internal_adapter.update_user(user["id"], email: email, emailVerified: true)
        call_email_verification_option(ctx, :on_email_verification, updated)
        call_email_verification_option(ctx, :after_email_verification, updated)

        if ctx.context.options.email_verification[:auto_sign_in_after_verification]
          session = ctx.context.internal_adapter.create_session(updated["id"])
          Cookies.set_session_cookie(ctx, {session: session, user: updated})
          next ctx.json({status: true, token: session["token"], user: Schema.parse_output(ctx.context.options, "user", updated)})
        end

        current = Routes.current_session(ctx, allow_nil: true)
        Cookies.set_session_cookie(ctx, {session: current[:session], user: updated}) if current
        ctx.json({status: true, token: nil, user: Schema.parse_output(ctx.context.options, "user", updated)})
      end
    end

    def sign_in_email_otp_endpoint(config)
      Endpoint.new(
        path: "/sign-in/email-otp",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "signInEmailOTP",
            description: "Sign in with an email OTP",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  email: {type: "string"},
                  otp: {type: "string"}
                },
                required: ["email", "otp"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response(
                "Signed in",
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
        body = normalize_hash(ctx.body)
        email = body[:email].to_s.downcase
        otp = body[:otp].to_s

        email_otp_verify!(ctx, config, email: email, type: "sign-in", otp: otp)
        found = ctx.context.internal_adapter.find_user_by_email(email)
        user = if found
          found[:user]
        else
          raise APIError.new("BAD_REQUEST", message: EMAIL_OTP_ERROR_CODES["INVALID_OTP"]) if config[:disable_sign_up]

          ctx.context.internal_adapter.create_user(email_otp_sign_up_user_data(ctx, body, email), context: ctx)
        end

        unless user["emailVerified"]
          user = ctx.context.internal_adapter.update_user(user["id"], emailVerified: true)
        end

        session = ctx.context.internal_adapter.create_session(user["id"])
        Cookies.set_session_cookie(ctx, {session: session, user: user})
        ctx.json({token: session["token"], user: Schema.parse_output(ctx.context.options, "user", user)})
      end
    end

    def request_email_change_email_otp_endpoint(config)
      Endpoint.new(
        path: "/email-otp/request-email-change",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "requestEmailChangeOTP",
            description: "Request an OTP to change the current user's email",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  newEmail: {type: "string"},
                  otp: {type: ["string", "null"]}
                },
                required: ["newEmail"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response("Change email OTP sent", OpenAPI.success_response_schema)
            }
          }
        }
      ) do |ctx|
        email_otp_change_email_enabled!(config)
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        current_email = session[:user]["email"].to_s.downcase
        new_email = body[:new_email].to_s.downcase
        validate_email_otp_email!(new_email)
        raise APIError.new("BAD_REQUEST", message: "Email is the same") if new_email == current_email

        if config.dig(:change_email, :verify_current_email)
          raise APIError.new("BAD_REQUEST", message: "OTP is required to verify current email") if body[:otp].to_s.empty?
          email_otp_verify!(ctx, config, email: current_email, type: "email-verification", otp: body[:otp])
        end

        otp = email_otp_resolve(ctx, config, email: new_email, type: "change-email", identifier_email: "#{current_email}-#{new_email}")
        if ctx.context.internal_adapter.find_user_by_email(new_email)
          ctx.context.internal_adapter.delete_verification_by_identifier(email_otp_identifier("#{current_email}-#{new_email}", "change-email"))
          next ctx.json({success: true})
        end

        email_otp_deliver(config, {email: new_email, otp: otp, type: "change-email"}, ctx)
        ctx.json({success: true})
      end
    end

    def change_email_email_otp_endpoint(config)
      Endpoint.new(
        path: "/email-otp/change-email",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "changeEmailWithEmailOTP",
            description: "Change the current user's email with an OTP",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  newEmail: {type: "string"},
                  otp: {type: "string"}
                },
                required: ["newEmail", "otp"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response("Email changed", OpenAPI.success_response_schema)
            }
          }
        }
      ) do |ctx|
        email_otp_change_email_enabled!(config)
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        current_email = session[:user]["email"].to_s.downcase
        new_email = body[:new_email].to_s.downcase
        validate_email_otp_email!(new_email)
        raise APIError.new("BAD_REQUEST", message: "Email is the same") if new_email == current_email

        email_otp_verify!(ctx, config, email: "#{current_email}-#{new_email}", type: "change-email", otp: body[:otp].to_s)
        raise APIError.new("BAD_REQUEST", message: "Email already in use") if ctx.context.internal_adapter.find_user_by_email(new_email)

        current = ctx.context.internal_adapter.find_user_by_email(current_email)
        raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES["USER_NOT_FOUND"]) unless current

        call_email_verification_option(ctx, :before_email_verification, current[:user])
        updated = ctx.context.internal_adapter.update_user(current[:user]["id"], email: new_email, emailVerified: true)
        call_email_verification_option(ctx, :after_email_verification, updated)
        Cookies.set_session_cookie(ctx, {session: session[:session], user: updated})
        ctx.json({success: true})
      end
    end

    def request_password_reset_email_otp_endpoint(config)
      Endpoint.new(
        path: "/email-otp/request-password-reset",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "requestPasswordResetEmailOTP",
            description: "Request a password reset OTP by email",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  email: {type: "string"}
                },
                required: ["email"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response("Password reset OTP requested", OpenAPI.status_response_schema)
            }
          }
        }
      ) do |ctx|
        email_otp_password_reset_request(ctx, config)
      end
    end

    def reset_password_email_otp_endpoint(config)
      Endpoint.new(
        path: "/email-otp/reset-password",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "resetPasswordEmailOTP",
            description: "Reset a password with an email OTP",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  email: {type: "string"},
                  otp: {type: "string"},
                  password: {type: "string"}
                },
                required: ["email", "otp", "password"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response("Password reset", OpenAPI.status_response_schema)
            }
          }
        }
      ) do |ctx|
        body = normalize_hash(ctx.body)
        email = body[:email].to_s.downcase
        otp = body[:otp].to_s
        password = body[:password].to_s

        email_otp_verify!(ctx, config, email: email, type: "forget-password", otp: otp)
        found = ctx.context.internal_adapter.find_user_by_email(email, include_accounts: true)
        raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES["USER_NOT_FOUND"]) unless found

        Routes.validate_password_length!(password, ctx.context.options.email_and_password)
        hashed = Routes.hash_password(ctx, password)
        account = found[:accounts].find { |entry| entry["providerId"] == "credential" }
        if account
          ctx.context.internal_adapter.update_password(found[:user]["id"], hashed)
        else
          ctx.context.internal_adapter.create_account(userId: found[:user]["id"], providerId: "credential", accountId: found[:user]["id"], password: hashed)
        end

        ctx.context.internal_adapter.update_user(found[:user]["id"], emailVerified: true) unless found[:user]["emailVerified"]
        callback = ctx.context.options.email_and_password[:on_password_reset]
        callback.call({user: found[:user]}, ctx.request) if callback.respond_to?(:call)
        ctx.context.internal_adapter.delete_sessions(found[:user]["id"]) if ctx.context.options.email_and_password[:revoke_sessions_on_password_reset]
        ctx.json({success: true})
      end
    end

    def email_otp_after_sign_up(ctx, config)
      response = ctx.returned
      user = fetch_value(response, :user)
      email = fetch_value(user, :email).to_s.downcase
      return unless Routes::EMAIL_PATTERN.match?(email)

      otp = email_otp_generate(config, email: email, type: "email-verification", ctx: ctx)
      email_otp_store(ctx, config, email: email, type: "email-verification", otp: otp)
      email_otp_deliver(config, {email: email, otp: otp, type: "email-verification"}, ctx)
      nil
    end

    def email_otp_password_reset_request(ctx, config)
      body = normalize_hash(ctx.body)
      email = body[:email].to_s.downcase
      otp = email_otp_resolve(ctx, config, email: email, type: "forget-password")

      found = ctx.context.internal_adapter.find_user_by_email(email)
      unless found
        ctx.context.internal_adapter.delete_verification_by_identifier(email_otp_identifier(email, "forget-password"))
        return ctx.json({success: true})
      end

      email_otp_deliver(config, {email: email, otp: otp, type: "forget-password"}, ctx)
      ctx.json({success: true})
    end

    def email_otp_send_verification(ctx, config, email:, type:)
      otp = email_otp_resolve(ctx, config, email: email, type: type)
      found = ctx.context.internal_adapter.find_user_by_email(email)

      unless found
        if type == "sign-in" && !config[:disable_sign_up]
          # Upstream allows sign-in OTP creation for new users when sign-up is enabled.
        else
          ctx.context.internal_adapter.delete_verification_by_identifier(email_otp_identifier(email, type))
          return
        end
      end

      email_otp_deliver(config, {email: email, otp: otp, type: type}, ctx)
    end

    def email_otp_store(ctx, config, email:, type:, otp:)
      stored = email_otp_stored_value(ctx, config, otp)
      identifier = email_otp_identifier(email, type)
      ctx.context.internal_adapter.delete_verification_by_identifier(identifier)
      ctx.context.internal_adapter.create_verification_value(
        identifier: identifier,
        value: "#{stored}:0",
        expiresAt: Time.now + config[:expires_in].to_i
      )
    end

    def email_otp_resolve(ctx, config, email:, type:, identifier_email: email)
      if config[:resend_strategy].to_s == "reuse"
        reused = email_otp_reuse(ctx, config, email: identifier_email, type: type)
        return reused if reused
      end

      otp = email_otp_generate(config, email: email, type: type, ctx: ctx)
      email_otp_store(ctx, config, email: identifier_email, type: type, otp: otp)
      otp
    end

    def email_otp_reuse(ctx, config, email:, type:)
      identifier = email_otp_identifier(email, type)
      verification = ctx.context.internal_adapter.find_verification_value(identifier)
      return nil unless verification && !Routes.expired_time?(verification["expiresAt"])

      stored_otp, attempts = email_otp_split(verification["value"])
      return nil if attempts.to_i >= config[:allowed_attempts].to_i

      plain = email_otp_plain_value(ctx, config, stored_otp)
      return nil unless plain

      ctx.context.internal_adapter.update_verification_value(verification["id"], expiresAt: Time.now + config[:expires_in].to_i)
      plain
    end

    def email_otp_verify!(ctx, config, email:, type:, otp:, consume: true)
      verification = ctx.context.internal_adapter.find_verification_value(email_otp_identifier(email, type))
      raise APIError.new("BAD_REQUEST", message: EMAIL_OTP_ERROR_CODES["INVALID_OTP"]) unless verification

      if Routes.expired_time?(verification["expiresAt"])
        ctx.context.internal_adapter.delete_verification_value(verification["id"])
        raise APIError.new("BAD_REQUEST", message: EMAIL_OTP_ERROR_CODES["OTP_EXPIRED"])
      end

      otp_value, attempts = email_otp_split(verification["value"])
      attempts_count = attempts.to_i
      if attempts_count >= config[:allowed_attempts].to_i
        ctx.context.internal_adapter.delete_verification_value(verification["id"])
        raise APIError.new("FORBIDDEN", message: EMAIL_OTP_ERROR_CODES["TOO_MANY_ATTEMPTS"])
      end

      ctx.context.internal_adapter.delete_verification_value(verification["id"]) if consume
      unless email_otp_matches?(ctx, config, otp_value, otp)
        if consume
          ctx.context.internal_adapter.create_verification_value(
            identifier: email_otp_identifier(email, type),
            value: "#{otp_value}:#{attempts_count + 1}",
            expiresAt: verification["expiresAt"]
          )
        else
          ctx.context.internal_adapter.update_verification_value(verification["id"], value: "#{otp_value}:#{attempts_count + 1}")
        end
        raise APIError.new("BAD_REQUEST", message: EMAIL_OTP_ERROR_CODES["INVALID_OTP"])
      end

      true
    end

    def email_otp_generate(config, email:, type:, ctx:)
      generator = config[:generate_otp]
      generated = generator.call({email: email, type: type}, ctx) if generator.respond_to?(:call)
      return generated.to_s if generated && !generated.to_s.empty?

      Array.new(config[:otp_length].to_i) { SecureRandom.random_number(10).to_s }.join
    end

    def email_otp_sign_up_user_data(ctx, body, email)
      reserved = %i[email otp name image callback_url callbackURL callbackUrl]
      user_fields = Schema.auth_tables(ctx.context.options).fetch("user").fetch(:fields)
      core_fields = %w[id name email emailVerified image createdAt updatedAt]
      additional = body.each_with_object({}) do |(key, value), result|
        next if reserved.include?(key.to_sym)

        field = Schema.storage_key(key)
        attributes = user_fields[field]
        next unless attributes
        next if core_fields.include?(field)
        next if attributes[:input] == false

        result[field] = value
      end
      additional.merge(
        "email" => email,
        "emailVerified" => true,
        "name" => body[:name].to_s,
        "image" => body[:image]
      )
    end

    def email_otp_stored_value(ctx, config, otp)
      storage = config[:store_otp]
      return Crypto.sha256(otp, encoding: :base64url) if storage.to_s == "hashed"
      return Crypto.symmetric_encrypt(key: ctx.context.secret_config, data: otp) if storage.to_s == "encrypted"

      if storage.is_a?(Hash)
        return storage[:hash].call(otp) if storage[:hash].respond_to?(:call)
        return storage[:encrypt].call(otp) if storage[:encrypt].respond_to?(:call)
      end

      otp
    end

    def email_otp_matches?(ctx, config, stored_otp, otp)
      storage = config[:store_otp]
      actual, expected = if storage.to_s == "hashed"
        [Crypto.sha256(otp, encoding: :base64url), stored_otp]
      elsif storage.to_s == "encrypted"
        [Crypto.symmetric_decrypt(key: ctx.context.secret_config, data: stored_otp), otp]
      elsif storage.is_a?(Hash) && storage[:hash].respond_to?(:call)
        [storage[:hash].call(otp), stored_otp]
      elsif storage.is_a?(Hash) && storage[:decrypt].respond_to?(:call)
        [storage[:decrypt].call(stored_otp), otp]
      else
        [otp, stored_otp]
      end
      return false unless actual
      return false unless actual.to_s.bytesize == expected.to_s.bytesize

      Crypto.constant_time_compare(actual.to_s, expected.to_s)
    end

    def email_otp_plain_value(ctx, config, stored_otp)
      storage = config[:store_otp]
      return stored_otp if storage.to_s == "plain" || storage.nil?
      return Crypto.symmetric_decrypt(key: ctx.context.secret_config, data: stored_otp) if storage.to_s == "encrypted"
      return storage[:decrypt].call(stored_otp) if storage.is_a?(Hash) && storage[:decrypt].respond_to?(:call)

      nil
    end

    def email_otp_deliver(config, data, ctx)
      sender = config[:send_verification_otp]
      sender.call(data, ctx) if sender.respond_to?(:call)
    end

    def email_otp_identifier(email, type)
      "#{type}-otp-#{email}"
    end

    def email_otp_split(value)
      string = value.to_s
      index = string.rindex(":")
      return [string, ""] unless index

      [string[0...index], string[(index + 1)..]]
    end

    def validate_email_otp_email!(email)
      raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES["INVALID_EMAIL"]) unless Routes::EMAIL_PATTERN.match?(email)
    end

    def validate_email_otp_type!(type)
      return if %w[email-verification sign-in forget-password change-email].include?(type)

      raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES["VALIDATION_ERROR"])
    end

    def email_otp_change_email_enabled!(config)
      return if config.dig(:change_email, :enabled)

      raise APIError.new("BAD_REQUEST", message: "Change email with OTP is disabled")
    end

    def call_email_verification_option(ctx, key, user)
      callback = ctx.context.options.email_verification[key]
      callback.call(user, ctx.request) if callback.respond_to?(:call)
    end

    def email_otp_rate_limits(config)
      rate_limit = normalize_hash(config[:rate_limit] || {})
      window = rate_limit[:window] || 60
      max = rate_limit[:max] || 3
      %w[
        /email-otp/send-verification-otp
        /email-otp/check-verification-otp
        /email-otp/verify-email
        /sign-in/email-otp
        /email-otp/request-password-reset
        /email-otp/reset-password
        /email-otp/request-email-change
        /email-otp/change-email
      ].map do |path|
        {
          path_matcher: ->(request_path) { request_path == path },
          window: window,
          max: max
        }
      end
    end
  end
end
