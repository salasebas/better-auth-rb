# frozen_string_literal: true

require "json"

module BetterAuth
  # Shared OAuth state storage matching upstream's opaque-state adaptation.
  # State data is encrypted client-side for the cookie strategy or retrieved
  # and deleted from verification storage for the database strategy. Signed JWT state is
  # still accepted so in-flight legacy sign-in and link flows keep working.
  module OAuthState
    INTERNAL_KEYS = %w[
      callbackURL codeVerifier errorURL newUserURL expiresAt oauthState link requestSignUp
    ].freeze

    class Error < BetterAuth::Error
      attr_reader :code, :error_url

      def initialize(code, error_url: nil)
        @code = code
        @error_url = error_url
        super(code)
      end
    end

    module_function

    def generate(ctx, state_data, cookie_name: nil)
      state = Crypto.random_string(32)
      payload = stringify_keys(state_data).merge("oauthState" => state)

      if cookie_strategy?(ctx)
        cookie = ctx.context.create_auth_cookie(cookie_name || "oauth_state", max_age: 600)
        encrypted = Crypto.symmetric_encrypt(
          key: ctx.context.secret_config,
          data: JSON.generate(payload)
        )
        ctx.set_cookie(cookie.name, encrypted, cookie.attributes)
      else
        cookie = ctx.context.create_auth_cookie(cookie_name || "state", max_age: 300)
        ctx.set_signed_cookie(cookie.name, state, ctx.context.secret, cookie.attributes)
        verification = ctx.context.internal_adapter.create_verification_value(
          identifier: state,
          value: JSON.generate(payload),
          expiresAt: Time.now + 600
        )
        raise Error, "state_generation_error" unless verification
      end

      state
    end

    def parse(ctx, state)
      legacy = Crypto.verify_jwt(state.to_s, ctx.context.secret)
      return parse_legacy(ctx, state, legacy) if legacy

      parse_stored(ctx, state)
    rescue JSON::ParserError
      raise Error, "state_invalid"
    end

    def parse_stored(ctx, state)
      data = read_stored(ctx, state) { |payload| payload["oauthState"] || payload["state"] }
      validate_expiration!(data)
      data
    end

    def parse_generic(ctx, state, cookie_name:, skip_state_cookie_check: false)
      data = read_stored(ctx, state, cookie_name: cookie_name, skip_state_cookie_check: skip_state_cookie_check) do |payload|
        validate_generic_payload!(payload)
        payload["oauthState"]
      end

      if data["expiresAt"] < (Time.now.to_r * 1000).floor
        raise Error.new("state_mismatch", error_url: data["errorURL"])
      end
      data
    end

    def read_stored(ctx, state, cookie_name: nil, skip_state_cookie_check: false, &expected_nonce)
      raise Error, "state_not_found" if state.to_s.empty?

      if cookie_strategy?(ctx)
        parse_cookie_state(ctx, state, cookie_name || "oauth_state", &expected_nonce)
      else
        parse_database_state(ctx, state, cookie_name || "state", skip_state_cookie_check, &expected_nonce)
      end
    end

    def parse_legacy(ctx, state, data)
      cookie = ctx.context.create_auth_cookie("state", max_age: 600)
      stored = ctx.get_signed_cookie(cookie.name, ctx.context.secret)
      Cookies.expire_cookie(ctx, cookie) if ctx.request || stored
      valid = ctx.request ? stored == state : (stored.nil? || stored == state)
      return data if valid

      raise Error.new("state_mismatch", error_url: recovered_error_url(data))
    end

    def parse_cookie_state(ctx, state, cookie_name)
      cookie = ctx.context.create_auth_cookie(cookie_name)
      encrypted = ctx.get_cookie(cookie.name)
      raise Error, "state_mismatch" if encrypted.to_s.empty?

      data = begin
        decrypted = Crypto.symmetric_decrypt(key: ctx.context.secret_config, data: encrypted)
        JSON.parse(decrypted)
      rescue JSON::ParserError, ArgumentError, TypeError
        raise Error, "state_invalid"
      end

      expected = yield(data)
      unless expected == state
        raise Error.new("state_mismatch", error_url: recovered_error_url(data))
      end

      Cookies.expire_cookie(ctx, cookie)
      data
    end

    def parse_database_state(ctx, state, cookie_name, skip_state_cookie_check)
      preview = ctx.context.internal_adapter.find_verification_value(state)
      raise Error, "state_mismatch" unless preview

      data = JSON.parse(preview.fetch("value"))
      expected = yield(data)
      error_url = recovered_error_url(data)
      raise Error.new("state_mismatch", error_url: error_url) if expected && expected != state

      cookie = ctx.context.create_auth_cookie(cookie_name)
      stored = ctx.get_signed_cookie(cookie.name, ctx.context.secret)
      unless skip_state_cookie_check
        valid = ctx.request ? stored == state : (stored.nil? || stored == state)
        raise Error.new("state_mismatch", error_url: error_url) unless valid
      end

      Cookies.expire_cookie(ctx, cookie) if skip_state_cookie_check || ctx.request || stored
      ctx.context.internal_adapter.delete_verification_by_identifier(state)
      data
    end

    def validate_generic_payload!(data)
      raise Error, "state_invalid" unless data.is_a?(Hash)
      raise Error, "state_invalid" unless data["callbackURL"].is_a?(String) && data["codeVerifier"].is_a?(String)
      raise Error, "state_invalid" unless data["expiresAt"].is_a?(Numeric) && data["expiresAt"].finite?

      %w[errorURL newUserURL oauthState].each do |field|
        raise Error, "state_invalid" if data.key?(field) && !data[field].is_a?(String)
      end
      raise Error, "state_invalid" if data.key?("requestSignUp") && ![true, false].include?(data["requestSignUp"])
      return unless data.key?("link")

      link = data["link"]
      raise Error, "state_invalid" unless link.is_a?(Hash) && link["email"].is_a?(String)

      data["link"] = {"email" => link["email"], "userId" => coerce_link_user_id(link.fetch("userId", "undefined"))}
    end

    def coerce_link_user_id(value)
      case value
      when nil then "null"
      when Hash
        raise Error, "state_invalid" if value.key?("toString")
        "[object Object]"
      when Array then value.map { |entry| entry.nil? ? "" : coerce_link_user_id(entry) }.join(",")
      when Numeric then json_number_string(value.to_f)
      else value.to_s
      end
    end

    def json_number_string(number)
      return "0" if number.zero?
      return number.to_s unless number.finite?

      mantissa, exponent = number.to_s.split("e")
      mantissa = mantissa.delete_suffix(".0")
      return mantissa unless exponent

      power = Integer(exponent, 10)
      return "#{mantissa}e#{format("%+d", power)}" unless (-6..20).cover?(power)

      digits = mantissa.delete("-.")
      decimal = if power.negative?
        "0." + "0" * (-power - 1) + digits
      else
        digits.ljust(power + 1, "0").insert(power + 1, ".").delete_suffix(".")
      end
      number.negative? ? "-#{decimal}" : decimal
    end

    def validate_expiration!(data)
      expires_at = data["expiresAt"].to_i
      return data unless expires_at.positive? && Session.normalize_time(expires_at) < Time.now

      raise Error.new("state_mismatch", error_url: recovered_error_url(data))
    end

    def recovered_error_url(data)
      data["errorURL"] || data["errorCallbackURL"]
    end

    def cookie_strategy?(ctx)
      ctx.context.options.account[:store_state_strategy].to_s == "cookie"
    end

    def stringify_keys(value)
      return value.each_with_object({}) { |(key, object), result| result[key.to_s] = stringify_keys(object) } if value.is_a?(Hash)
      return value.map { |entry| stringify_keys(entry) } if value.is_a?(Array)

      value
    end
  end
end
