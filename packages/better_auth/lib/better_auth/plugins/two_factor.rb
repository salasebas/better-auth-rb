# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "securerandom"
require "uri"

module BetterAuth
  module Plugins
    TWO_FACTOR_ERROR_CODES = {
      "OTP_NOT_ENABLED" => "OTP not enabled",
      "OTP_HAS_EXPIRED" => "OTP has expired",
      "TOTP_NOT_ENABLED" => "TOTP not enabled",
      "TWO_FACTOR_NOT_ENABLED" => "Two factor isn't enabled",
      "BACKUP_CODES_NOT_ENABLED" => "Backup codes aren't enabled",
      "INVALID_BACKUP_CODE" => "Invalid backup code",
      "INVALID_CODE" => "Invalid code",
      "TOO_MANY_ATTEMPTS_REQUEST_NEW_CODE" => "Too many attempts. Please request a new code.",
      "INVALID_TWO_FACTOR_COOKIE" => "Invalid two factor cookie"
    }.freeze

    TWO_FACTOR_COOKIE_NAME = "two_factor"
    TRUST_DEVICE_COOKIE_NAME = "trust_device"
    TRUST_DEVICE_COOKIE_MAX_AGE = 30 * 24 * 60 * 60
    TWO_FACTOR_COOKIE_MAX_AGE = 10 * 60
    TWO_FACTOR_MODEL = "twoFactor"

    module_function

    def two_factor(options = {})
      config = {
        two_factor_table: "twoFactor",
        trust_device_max_age: TRUST_DEVICE_COOKIE_MAX_AGE,
        two_factor_cookie_max_age: TWO_FACTOR_COOKIE_MAX_AGE,
        backup_code_options: {store_backup_codes: "encrypted"},
        otp_options: {},
        totp_options: {}
      }.merge(normalize_hash(options))
      config[:backup_code_options] = {store_backup_codes: "encrypted"}.merge(normalize_hash(config[:backup_code_options]))
      config[:otp_options] = normalize_hash(config[:otp_options])
      config[:totp_options] = normalize_hash(config[:totp_options])
      config[:backup_code_options][:allow_passwordless] = config[:allow_passwordless] unless config[:backup_code_options].key?(:allow_passwordless)
      config[:totp_options][:allow_passwordless] = config[:allow_passwordless] unless config[:totp_options].key?(:allow_passwordless)

      Plugin.new(
        id: "two-factor",
        endpoints: {
          enable_two_factor: two_factor_enable_endpoint(config),
          disable_two_factor: two_factor_disable_endpoint(config),
          generate_totp: two_factor_generate_totp_endpoint(config),
          get_totp_uri: two_factor_get_totp_uri_endpoint(config),
          verify_totp: two_factor_verify_totp_endpoint(config),
          send_two_factor_otp: two_factor_send_otp_endpoint(config),
          verify_two_factor_otp: two_factor_verify_otp_endpoint(config),
          verify_backup_code: two_factor_verify_backup_code_endpoint(config),
          generate_backup_codes: two_factor_generate_backup_codes_endpoint(config),
          view_backup_codes: two_factor_view_backup_codes_endpoint(config)
        },
        hooks: {
          after: [
            {
              matcher: ->(ctx) { ["/sign-in/email", "/sign-in/username", "/sign-in/phone-number"].include?(ctx.path) },
              handler: ->(ctx) { two_factor_after_sign_in(ctx, config) }
            }
          ]
        },
        schema: two_factor_schema(config),
        rate_limit: [
          {
            path_matcher: ->(path) { path.start_with?("/two-factor/") },
            window: 10,
            max: 3
          }
        ],
        error_codes: TWO_FACTOR_ERROR_CODES,
        options: config
      )
    end

    def two_factor_enable_endpoint(config)
      Endpoint.new(path: "/two-factor/enable", method: "POST", metadata: two_factor_openapi("enableTwoFactor", "Enable two factor authentication", two_factor_enable_response_schema)) do |ctx|
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        two_factor_check_password!(ctx, session[:user]["id"], body[:password], allow_passwordless: config[:allow_passwordless])

        secret = two_factor_generate_secret
        backup = two_factor_generate_backup_codes(ctx.context.secret_config, config[:backup_code_options])
        if config[:skip_verification_on_enable]
          updated_user = ctx.context.internal_adapter.update_user(session[:user]["id"], twoFactorEnabled: true)
          new_session = ctx.context.internal_adapter.create_session(updated_user["id"], false)
          Cookies.set_session_cookie(ctx, {session: new_session, user: updated_user})
          ctx.context.internal_adapter.delete_session(session[:session]["token"])
        end

        existing = two_factor_record(ctx, config, session[:user]["id"])
        verified = (!!existing && existing["verified"] != false) || !!config[:skip_verification_on_enable]
        ctx.context.adapter.delete_many(model: TWO_FACTOR_MODEL, where: [{field: "userId", value: session[:user]["id"]}])
        ctx.context.adapter.create(
          model: TWO_FACTOR_MODEL,
          data: {
            secret: Crypto.symmetric_encrypt(key: ctx.context.secret_config, data: secret),
            backupCodes: backup[:stored],
            userId: session[:user]["id"],
            verified: verified
          },
          force_allow_id: true
        )

        ctx.json({
          totpURI: two_factor_totp_uri(secret, issuer: body[:issuer] || config[:issuer] || ctx.context.app_name, account: session[:user]["email"], options: config[:totp_options]),
          backupCodes: backup[:codes]
        })
      end
    end

    def two_factor_disable_endpoint(config)
      Endpoint.new(path: "/two-factor/disable", method: "POST", metadata: two_factor_openapi("disableTwoFactor", "Disable two factor authentication", OpenAPI.status_response_schema)) do |ctx|
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        two_factor_check_password!(ctx, session[:user]["id"], body[:password], allow_passwordless: config[:allow_passwordless])

        updated_user = ctx.context.internal_adapter.update_user(session[:user]["id"], twoFactorEnabled: false)
        ctx.context.adapter.delete(model: TWO_FACTOR_MODEL, where: [{field: "userId", value: updated_user["id"]}])
        new_session = ctx.context.internal_adapter.create_session(updated_user["id"], false)
        Cookies.set_session_cookie(ctx, {session: new_session, user: updated_user})
        ctx.context.internal_adapter.delete_session(session[:session]["token"])

        trust_cookie = ctx.context.create_auth_cookie(TRUST_DEVICE_COOKIE_NAME, max_age: config[:trust_device_max_age])
        trust_value = ctx.get_signed_cookie(trust_cookie.name, ctx.context.secret)
        if trust_value
          _token, identifier = trust_value.split("!", 2)
          ctx.context.internal_adapter.delete_verification_by_identifier(identifier) if identifier
          Cookies.expire_cookie(ctx, trust_cookie)
        end
        ctx.json({status: true})
      end
    end

    def two_factor_generate_totp_endpoint(config)
      Endpoint.new(path: "/totp/generate", method: "POST", metadata: two_factor_openapi("generateTOTP", "Generate a TOTP code", OpenAPI.object_schema({code: {type: "string"}}, required: ["code"]))) do |ctx|
        two_factor_totp_enabled!(config)
        body = normalize_hash(ctx.body)
        ctx.json({code: two_factor_totp(body[:secret], options: config[:totp_options])})
      end
    end

    def two_factor_get_totp_uri_endpoint(config)
      Endpoint.new(path: "/two-factor/get-totp-uri", method: "POST", metadata: two_factor_openapi("getTOTPURI", "Get the TOTP URI", OpenAPI.object_schema({totpURI: {type: "string"}}, required: ["totpURI"]))) do |ctx|
        two_factor_totp_enabled!(config)
        session = Routes.current_session(ctx)
        two_factor_check_password!(ctx, session[:user]["id"], normalize_hash(ctx.body)[:password], allow_passwordless: config[:totp_options][:allow_passwordless])
        record = two_factor_record(ctx, config, session[:user]["id"])
        raise APIError.new("BAD_REQUEST", message: TWO_FACTOR_ERROR_CODES["TOTP_NOT_ENABLED"]) unless record

        secret = Crypto.symmetric_decrypt(key: ctx.context.secret_config, data: record["secret"])
        ctx.json({totpURI: two_factor_totp_uri(secret, issuer: config[:issuer] || ctx.context.app_name, account: session[:user]["email"], options: config[:totp_options])})
      end
    end

    def two_factor_verify_totp_endpoint(config)
      Endpoint.new(path: "/two-factor/verify-totp", method: "POST", metadata: two_factor_openapi("verifyTOTP", "Verify a TOTP code", two_factor_verification_response_schema)) do |ctx|
        two_factor_totp_enabled!(config)
        body = normalize_hash(ctx.body)
        data = two_factor_verification_context(ctx, config)
        record = two_factor_record(ctx, config, data[:session][:user]["id"])
        raise APIError.new("BAD_REQUEST", message: TWO_FACTOR_ERROR_CODES["TOTP_NOT_ENABLED"]) unless record
        if !data[:session][:session] && record["verified"] == false
          raise APIError.new("BAD_REQUEST", message: TWO_FACTOR_ERROR_CODES["TOTP_NOT_ENABLED"])
        end

        secret = Crypto.symmetric_decrypt(key: ctx.context.secret_config, data: record["secret"])
        raise APIError.new("UNAUTHORIZED", message: TWO_FACTOR_ERROR_CODES["INVALID_CODE"]) unless two_factor_totp_valid?(secret, body[:code], options: config[:totp_options])

        if record["verified"] != true
          if !data[:session][:user]["twoFactorEnabled"] && data[:session][:session]
            updated_user = ctx.context.internal_adapter.update_user(data[:session][:user]["id"], twoFactorEnabled: true)
            new_session = ctx.context.internal_adapter.create_session(updated_user["id"], false)
            ctx.context.internal_adapter.delete_session(data[:session][:session]["token"])
            Cookies.set_session_cookie(ctx, {session: new_session, user: updated_user})
          end
          ctx.context.adapter.update(model: TWO_FACTOR_MODEL, where: [{field: "id", value: record["id"]}], update: {verified: true})
        elsif !data[:session][:user]["twoFactorEnabled"] && data[:session][:session]
          updated_user = ctx.context.internal_adapter.update_user(data[:session][:user]["id"], twoFactorEnabled: true)
          new_session = ctx.context.internal_adapter.create_session(updated_user["id"], false)
          ctx.context.internal_adapter.delete_session(data[:session][:session]["token"])
          Cookies.set_session_cookie(ctx, {session: new_session, user: updated_user})
        end
        data[:valid].call
      end
    end

    def two_factor_send_otp_endpoint(config)
      Endpoint.new(path: "/two-factor/send-otp", method: "POST", metadata: two_factor_openapi("sendTwoFactorOTP", "Send a two factor OTP", OpenAPI.status_response_schema)) do |ctx|
        otp_config = config[:otp_options]
        sender = otp_config[:send_otp]
        unless sender.respond_to?(:call)
          raise APIError.new("BAD_REQUEST", message: "otp isn't configured")
        end

        data = two_factor_verification_context(ctx, config)
        code = two_factor_random_digits((otp_config[:digits] || 6).to_i)
        stored = two_factor_store_otp_value(ctx, code, otp_config)
        ctx.context.internal_adapter.create_verification_value(
          identifier: "2fa-otp-#{data[:key]}",
          value: "#{stored}:0",
          expiresAt: Time.now + ((otp_config[:period] || 3).to_i * 60)
        )
        sender.call({user: data[:session][:user], otp: code}, ctx)
        ctx.json({status: true})
      end
    end

    def two_factor_verify_otp_endpoint(config)
      Endpoint.new(path: "/two-factor/verify-otp", method: "POST", metadata: two_factor_openapi("verifyTwoFactorOTP", "Verify a two factor OTP", two_factor_verification_response_schema)) do |ctx|
        body = normalize_hash(ctx.body)
        data = two_factor_verification_context(ctx, config)
        verification = ctx.context.internal_adapter.find_verification_value("2fa-otp-#{data[:key]}")
        stored, counter = verification&.fetch("value", nil).to_s.split(":", 2)
        if !verification || verification["expiresAt"] < Time.now
          ctx.context.internal_adapter.delete_verification_value(verification["id"]) if verification
          raise APIError.new("BAD_REQUEST", message: TWO_FACTOR_ERROR_CODES["OTP_HAS_EXPIRED"])
        end

        allowed = (config[:otp_options][:allowed_attempts] || 5).to_i
        if counter.to_i >= allowed
          ctx.context.internal_adapter.delete_verification_value(verification["id"])
          raise APIError.new("BAD_REQUEST", message: TWO_FACTOR_ERROR_CODES["TOO_MANY_ATTEMPTS_REQUEST_NEW_CODE"])
        end

        unless two_factor_otp_matches?(ctx, stored, body[:code].to_s, config[:otp_options])
          ctx.context.internal_adapter.update_verification_value(verification["id"], value: "#{stored}:#{counter.to_i + 1}")
          raise APIError.new("UNAUTHORIZED", message: TWO_FACTOR_ERROR_CODES["INVALID_CODE"])
        end

        if !data[:session][:user]["twoFactorEnabled"] && data[:session][:session]
          updated_user = ctx.context.internal_adapter.update_user(data[:session][:user]["id"], twoFactorEnabled: true)
          new_session = ctx.context.internal_adapter.create_session(updated_user["id"], false)
          ctx.context.internal_adapter.delete_session(data[:session][:session]["token"])
          Cookies.set_session_cookie(ctx, {session: new_session, user: updated_user})
          next ctx.json({token: new_session["token"], user: Schema.parse_output(ctx.context.options, "user", updated_user)})
        end

        data[:valid].call
      end
    end

    def two_factor_verify_backup_code_endpoint(config)
      Endpoint.new(path: "/two-factor/verify-backup-code", method: "POST", metadata: two_factor_openapi("verifyBackupCode", "Verify a two factor backup code", two_factor_verification_response_schema)) do |ctx|
        body = normalize_hash(ctx.body)
        data = two_factor_verification_context(ctx, config)
        record = two_factor_record(ctx, config, data[:session][:user]["id"])
        raise APIError.new("BAD_REQUEST", message: TWO_FACTOR_ERROR_CODES["BACKUP_CODES_NOT_ENABLED"]) unless record

        codes = two_factor_read_backup_codes(ctx.context.secret_config, record["backupCodes"], config[:backup_code_options])
        unless codes.include?(body[:code].to_s)
          raise APIError.new("UNAUTHORIZED", message: TWO_FACTOR_ERROR_CODES["INVALID_BACKUP_CODE"])
        end

        remaining = codes.reject { |code| code == body[:code].to_s }
        stored = two_factor_store_backup_codes(ctx.context.secret_config, remaining, config[:backup_code_options])
        updated = ctx.context.adapter.update(
          model: TWO_FACTOR_MODEL,
          where: [{field: "id", value: record["id"]}, {field: "backupCodes", value: record["backupCodes"]}],
          update: {backupCodes: stored}
        )
        raise APIError.new("CONFLICT", message: "Failed to verify backup code. Please try again.") unless updated

        body[:disable_session] ? ctx.json({token: data[:session][:session]&.fetch("token", nil), user: Schema.parse_output(ctx.context.options, "user", data[:session][:user])}) : data[:valid].call
      end
    end

    def two_factor_generate_backup_codes_endpoint(config)
      Endpoint.new(path: "/two-factor/generate-backup-codes", method: "POST", metadata: two_factor_openapi("generateBackupCodes", "Generate two factor backup codes", two_factor_backup_codes_response_schema)) do |ctx|
        session = Routes.current_session(ctx)
        raise APIError.new("BAD_REQUEST", message: TWO_FACTOR_ERROR_CODES["TWO_FACTOR_NOT_ENABLED"]) unless session[:user]["twoFactorEnabled"]

        two_factor_check_password!(ctx, session[:user]["id"], normalize_hash(ctx.body)[:password], allow_passwordless: config[:backup_code_options][:allow_passwordless])
        record = two_factor_record(ctx, config, session[:user]["id"])
        raise APIError.new("BAD_REQUEST", message: TWO_FACTOR_ERROR_CODES["TWO_FACTOR_NOT_ENABLED"]) unless record

        backup = two_factor_generate_backup_codes(ctx.context.secret_config, config[:backup_code_options])
        ctx.context.adapter.update(model: TWO_FACTOR_MODEL, where: [{field: "id", value: record["id"]}], update: {backupCodes: backup[:stored]})
        ctx.json({status: true, backupCodes: backup[:codes]})
      end
    end

    def two_factor_view_backup_codes_endpoint(config)
      Endpoint.new(method: "POST") do |ctx|
        body = normalize_hash(ctx.body)
        record = two_factor_record(ctx, config, body[:user_id])
        raise APIError.new("BAD_REQUEST", message: TWO_FACTOR_ERROR_CODES["BACKUP_CODES_NOT_ENABLED"]) unless record

        ctx.json({status: true, backupCodes: two_factor_read_backup_codes(ctx.context.secret_config, record["backupCodes"], config[:backup_code_options])})
      end
    end

    def two_factor_openapi(operation_id, description, response_schema)
      {
        openapi: {
          operationId: operation_id,
          description: description,
          requestBody: two_factor_request_body(operation_id),
          responses: {
            "200" => OpenAPI.json_response("Success", response_schema)
          }
        }
      }
    end

    def two_factor_request_body(operation_id)
      schema = case operation_id
      when "enableTwoFactor"
        OpenAPI.object_schema({password: {type: "string"}, issuer: {type: "string"}})
      when "disableTwoFactor", "getTOTPURI", "generateBackupCodes"
        OpenAPI.object_schema({password: {type: "string"}})
      when "generateTOTP"
        OpenAPI.object_schema({secret: {type: "string"}}, required: ["secret"])
      when "verifyTOTP", "verifyTwoFactorOTP"
        OpenAPI.object_schema({code: {type: "string"}, trustDevice: {type: "boolean"}, trust_device: {type: "boolean"}}, required: ["code"])
      when "verifyBackupCode"
        OpenAPI.object_schema({code: {type: "string"}, disableSession: {type: "boolean"}, disable_session: {type: "boolean"}, trustDevice: {type: "boolean"}, trust_device: {type: "boolean"}}, required: ["code"])
      when "sendTwoFactorOTP"
        OpenAPI.empty_request_body.dig(:content, "application/json", :schema)
      else
        {type: "object", properties: {}}
      end
      OpenAPI.json_request_body(schema)
    end

    def two_factor_enable_response_schema
      OpenAPI.object_schema(
        {
          totpURI: {type: "string"},
          backupCodes: {type: "array", items: {type: "string"}}
        },
        required: ["totpURI", "backupCodes"]
      )
    end

    def two_factor_verification_response_schema
      OpenAPI.object_schema(
        {
          token: {type: ["string", "null"]},
          user: {type: ["object", "null"], "$ref": "#/components/schemas/User"},
          status: {type: ["boolean", "null"]}
        }
      )
    end

    def two_factor_backup_codes_response_schema
      OpenAPI.object_schema(
        {
          status: {type: "boolean"},
          backupCodes: {type: "array", items: {type: "string"}}
        },
        required: ["status", "backupCodes"]
      )
    end

    def two_factor_schema(config = {})
      custom_schema = config[:schema]
      base = {
        user: {
          fields: {
            twoFactorEnabled: {type: "boolean", required: false, default_value: false, returned: true}
          }
        },
        twoFactor: {
          fields: {
            secret: {type: "string", required: true, returned: false, index: true},
            backupCodes: {type: "string", required: true, returned: false},
            userId: {type: "string", required: true, returned: false, index: true, references: {model: "user", field: "id"}},
            verified: {type: "boolean", required: false, default_value: true, input: false}
          }
        }
      }
      if config[:two_factor_table] && config[:two_factor_table] != TWO_FACTOR_MODEL
        base[:twoFactor][:model_name] = config[:two_factor_table].to_s
      end
      deep_merge_hashes(base, normalize_hash(custom_schema || {}))
    end

    def two_factor_after_sign_in(ctx, config)
      data = ctx.context.new_session
      return unless data && data[:user] && data[:session]
      return unless data[:user]["twoFactorEnabled"]
      return if two_factor_trusted_device_valid?(ctx, config, data[:user]["id"])

      Cookies.delete_session_cookie(ctx, skip_dont_remember_me: true)
      ctx.context.internal_adapter.delete_session(data[:session]["token"])
      cookie = ctx.context.create_auth_cookie(TWO_FACTOR_COOKIE_NAME, max_age: config[:two_factor_cookie_max_age])
      identifier = "2fa-#{Crypto.random_string(20)}"
      ctx.context.internal_adapter.create_verification_value(
        identifier: identifier,
        value: data[:user]["id"],
        expiresAt: Time.now + config[:two_factor_cookie_max_age].to_i
      )
      ctx.set_signed_cookie(cookie.name, identifier, ctx.context.secret, cookie.attributes)
      ctx.json({twoFactorRedirect: true, twoFactorMethods: two_factor_methods(ctx, config, data[:user]["id"])})
    end

    def two_factor_verification_context(ctx, config)
      session = Routes.current_session(ctx, allow_nil: true)
      if session
        key = "#{session[:user]["id"]}!#{session[:session]["id"]}"
        return {session: session, key: key, valid: -> { ctx.json({token: session[:session]["token"], user: Schema.parse_output(ctx.context.options, "user", session[:user])}) }}
      end

      cookie = ctx.context.create_auth_cookie(TWO_FACTOR_COOKIE_NAME)
      identifier = ctx.get_signed_cookie(cookie.name, ctx.context.secret)
      raise APIError.new("UNAUTHORIZED", message: TWO_FACTOR_ERROR_CODES["INVALID_TWO_FACTOR_COOKIE"]) unless identifier

      verification = ctx.context.internal_adapter.find_verification_value(identifier)
      raise APIError.new("UNAUTHORIZED", message: TWO_FACTOR_ERROR_CODES["INVALID_TWO_FACTOR_COOKIE"]) unless verification && verification["expiresAt"] > Time.now

      user = ctx.context.internal_adapter.find_user_by_id(verification["value"])
      raise APIError.new("UNAUTHORIZED", message: TWO_FACTOR_ERROR_CODES["INVALID_TWO_FACTOR_COOKIE"]) unless user

      valid = lambda do
        dont_remember_me = Cookies.dont_remember?(ctx)
        new_session = ctx.context.internal_adapter.create_session(user["id"], dont_remember_me)
        raise APIError.new("INTERNAL_SERVER_ERROR", message: "failed to create session") unless new_session

        ctx.context.internal_adapter.delete_verification_value(verification["id"])
        Cookies.set_session_cookie(ctx, {session: new_session, user: user}, dont_remember_me)
        Cookies.expire_cookie(ctx, cookie)
        if normalize_hash(ctx.body)[:trust_device]
          two_factor_set_trusted_device(ctx, config, user["id"])
          Cookies.expire_cookie(ctx, ctx.context.auth_cookies[:dont_remember])
        end
        ctx.json({token: new_session["token"], user: Schema.parse_output(ctx.context.options, "user", user)})
      end

      {session: {session: nil, user: user}, key: identifier, valid: valid}
    end

    def two_factor_set_trusted_device(ctx, config, user_id)
      max_age = config[:trust_device_max_age].to_i
      identifier = "trust-device-#{Crypto.random_string(32)}"
      token = Crypto.hmac_signature("#{user_id}!#{identifier}", ctx.context.secret, encoding: :base64url)
      ctx.context.internal_adapter.create_verification_value(identifier: identifier, value: user_id, expiresAt: Time.now + max_age)
      cookie = ctx.context.create_auth_cookie(TRUST_DEVICE_COOKIE_NAME, max_age: max_age)
      ctx.set_signed_cookie(cookie.name, "#{token}!#{identifier}", ctx.context.secret, cookie.attributes)
    end

    def two_factor_trusted_device_valid?(ctx, config, user_id)
      cookie = ctx.context.create_auth_cookie(TRUST_DEVICE_COOKIE_NAME, max_age: config[:trust_device_max_age])
      value = ctx.get_signed_cookie(cookie.name, ctx.context.secret)
      return false unless value

      token, identifier = value.split("!", 2)
      expected = Crypto.hmac_signature("#{user_id}!#{identifier}", ctx.context.secret, encoding: :base64url)
      verification = identifier && ctx.context.internal_adapter.find_verification_value(identifier)
      if token && identifier && Crypto.constant_time_compare(token, expected) && verification && verification["value"] == user_id && verification["expiresAt"] > Time.now
        ctx.context.internal_adapter.delete_verification_value(verification["id"])
        two_factor_set_trusted_device(ctx, config, user_id)
        true
      else
        Cookies.expire_cookie(ctx, cookie)
        false
      end
    end

    def two_factor_record(ctx, config, user_id)
      ctx.context.adapter.find_one(model: TWO_FACTOR_MODEL, where: [{field: "userId", value: user_id}])
    end

    def two_factor_methods(ctx, config, user_id)
      methods = []
      unless config[:totp_options][:disable]
        record = two_factor_record(ctx, config, user_id)
        methods << "totp" if record && record["verified"] != false
      end
      methods << "otp" if config[:otp_options][:send_otp].respond_to?(:call)
      methods
    end

    def two_factor_check_password!(ctx, user_id, password, allow_passwordless: false)
      account = ctx.context.internal_adapter.find_accounts(user_id).find { |entry| entry["providerId"] == "credential" }
      return if allow_passwordless && !account

      unless account && account["password"] && Routes.verify_password_value(ctx, password.to_s, account["password"])
        raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES["INVALID_PASSWORD"])
      end
    end

    def two_factor_totp_enabled!(config)
      if config[:totp_options][:disable]
        raise APIError.new("BAD_REQUEST", message: "totp isn't configured")
      end
    end

    def two_factor_generate_secret
      raw = SecureRandom.random_bytes(20)
      base32_encode(raw)
    end

    def two_factor_totp(secret, options: {})
      interval = Time.now.to_i / (options[:period] || 30).to_i
      two_factor_totp_at(secret, interval, digits: (options[:digits] || 6).to_i)
    end

    def two_factor_totp_valid?(secret, code, options: {})
      period = (options[:period] || 30).to_i
      interval = Time.now.to_i / period
      (-1..1).any? { |offset| Crypto.constant_time_compare(two_factor_totp_at(secret, interval + offset, digits: (options[:digits] || 6).to_i), code.to_s) }
    end

    def two_factor_totp_at(secret, counter, digits:)
      key = base32_decode(secret)
      digest = OpenSSL::HMAC.digest("SHA1", key, [counter].pack("Q>"))
      offset = digest.bytes.last & 0x0f
      binary = digest.byteslice(offset, 4).unpack1("N") & 0x7fffffff
      (binary % (10**digits)).to_s.rjust(digits, "0")
    end

    def two_factor_totp_uri(secret, issuer:, account:, options: {})
      label = "#{issuer}:#{account}"
      params = {secret: secret, issuer: issuer, digits: options[:digits] || 6, period: options[:period] || 30}
      "otpauth://totp/#{URI.encode_www_form_component(label)}?#{URI.encode_www_form(params)}"
    end

    def two_factor_generate_backup_codes(secret, options)
      codes = if options[:custom_backup_codes_generate].respond_to?(:call)
        options[:custom_backup_codes_generate].call
      else
        amount = (options[:amount] || 10).to_i
        length = (options[:length] || 10).to_i
        Array.new(amount) do
          value = Crypto.random_string(length)
          "#{value[0, 5]}-#{value[5..]}"
        end
      end
      {codes: codes, stored: two_factor_store_backup_codes(secret, codes, options)}
    end

    def two_factor_store_backup_codes(secret, codes, options)
      data = JSON.generate(codes)
      storage = options[:store_backup_codes]
      if storage == "encrypted"
        Crypto.symmetric_encrypt(key: secret, data: data)
      elsif storage.is_a?(Hash) && storage[:encrypt].respond_to?(:call)
        storage[:encrypt].call(data)
      else
        data
      end
    end

    def two_factor_read_backup_codes(secret, stored, options)
      storage = options[:store_backup_codes]
      data = if storage == "encrypted"
        Crypto.symmetric_decrypt(key: secret, data: stored)
      elsif storage.is_a?(Hash) && storage[:decrypt].respond_to?(:call)
        storage[:decrypt].call(stored)
      else
        stored
      end
      JSON.parse(data.to_s)
    rescue JSON::ParserError
      []
    end

    def two_factor_random_digits(length)
      Array.new(length) { SecureRandom.random_number(10) }.join
    end

    def two_factor_store_otp_value(ctx, code, options)
      storage = options[:store_otp]
      if storage == "hashed"
        Crypto.sha256(code, encoding: :base64url)
      elsif storage == "encrypted"
        Crypto.symmetric_encrypt(key: ctx.context.secret_config, data: code)
      elsif storage.is_a?(Hash) && storage[:hash].respond_to?(:call)
        storage[:hash].call(code)
      elsif storage.is_a?(Hash) && storage[:encrypt].respond_to?(:call)
        storage[:encrypt].call(code)
      else
        code
      end
    end

    def two_factor_otp_matches?(ctx, stored, input, options)
      storage = options[:store_otp]
      expected, actual = if storage == "hashed"
        [stored, Crypto.sha256(input, encoding: :base64url)]
      elsif storage == "encrypted"
        [Crypto.symmetric_decrypt(key: ctx.context.secret_config, data: stored), input]
      elsif storage.is_a?(Hash) && storage[:hash].respond_to?(:call)
        [stored, storage[:hash].call(input)]
      elsif storage.is_a?(Hash) && storage[:decrypt].respond_to?(:call)
        [storage[:decrypt].call(stored), input]
      else
        [stored, input]
      end
      expected && actual && Crypto.constant_time_compare(expected.to_s, actual.to_s)
    end

    BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

    def base32_encode(bytes)
      bits = bytes.bytes.map { |byte| byte.to_s(2).rjust(8, "0") }.join
      bits.scan(/.{1,5}/).map { |chunk| BASE32_ALPHABET[chunk.ljust(5, "0").to_i(2)] }.join
    end

    def base32_decode(value)
      clean = value.to_s.upcase.gsub(/[^A-Z2-7]/, "")
      bits = clean.chars.map { |char| BASE32_ALPHABET.index(char).to_i.to_s(2).rjust(5, "0") }.join
      bits.scan(/.{8}/).map { |byte| byte.to_i(2).chr }.join
    end
  end
end
