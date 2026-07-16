# frozen_string_literal: true

require "json"

module BetterAuth
  # Shared OAuth state storage matching upstream's opaque-state adaptation.
  # State data is encrypted client-side for the cookie strategy or consumed
  # from verification storage for the database strategy. Signed JWT state is
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

    def generate(ctx, state_data)
      state = Crypto.random_string(32)
      payload = stringify_keys(state_data).merge("oauthState" => state)

      if cookie_strategy?(ctx)
        cookie = ctx.context.create_auth_cookie("oauth_state", max_age: 600)
        encrypted = Crypto.symmetric_encrypt(
          key: ctx.context.secret_config,
          data: JSON.generate(payload)
        )
        ctx.set_cookie(cookie.name, encrypted, cookie.attributes)
      else
        cookie = ctx.context.create_auth_cookie("state", max_age: 300)
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
      raise Error, "state_not_found" if state.to_s.empty?

      legacy = Crypto.verify_jwt(state.to_s, ctx.context.secret)
      return parse_legacy(ctx, state, legacy) if legacy

      cookie_strategy?(ctx) ? parse_cookie_state(ctx, state) : parse_database_state(ctx, state)
    rescue JSON::ParserError
      raise Error, "state_invalid"
    end

    def parse_legacy(ctx, state, data)
      cookie = ctx.context.create_auth_cookie("state", max_age: 600)
      stored = ctx.get_signed_cookie(cookie.name, ctx.context.secret)
      Cookies.expire_cookie(ctx, cookie) if ctx.request || stored
      valid = ctx.request ? stored == state : (stored.nil? || stored == state)
      return data if valid

      raise Error.new("state_mismatch", error_url: recovered_error_url(data))
    end

    def parse_cookie_state(ctx, state)
      cookie = ctx.context.create_auth_cookie("oauth_state")
      encrypted = ctx.get_cookie(cookie.name)
      raise Error, "state_mismatch" if encrypted.to_s.empty?

      data = begin
        decrypted = Crypto.symmetric_decrypt(key: ctx.context.secret_config, data: encrypted)
        JSON.parse(decrypted)
      rescue JSON::ParserError, ArgumentError, TypeError
        raise Error, "state_invalid"
      end

      expected = data["oauthState"] || data["state"]
      unless expected == state
        raise Error.new("state_mismatch", error_url: recovered_error_url(data))
      end

      Cookies.expire_cookie(ctx, cookie)
      validate_expiration!(data)
      data
    end

    def parse_database_state(ctx, state)
      preview = ctx.context.internal_adapter.find_verification_value(state)
      raise Error, "state_mismatch" unless preview

      data = JSON.parse(preview.fetch("value"))
      error_url = recovered_error_url(data)
      expected = data["oauthState"] || data["state"]
      raise Error.new("state_mismatch", error_url: error_url) if expected && expected != state

      cookie = ctx.context.create_auth_cookie("state")
      stored = ctx.get_signed_cookie(cookie.name, ctx.context.secret)
      valid = ctx.request ? stored == state : (stored.nil? || stored == state)
      raise Error.new("state_mismatch", error_url: error_url) unless valid

      consumed = ctx.context.internal_adapter.consume_verification_value(state)
      Cookies.expire_cookie(ctx, cookie) if ctx.request || stored
      raise Error.new("state_mismatch", error_url: error_url) unless consumed

      consumed_data = JSON.parse(consumed.fetch("value"))
      consumed_expected = consumed_data["oauthState"] || consumed_data["state"]
      same_payload = consumed.fetch("value") == preview.fetch("value")
      expected_matches = !consumed_expected || consumed_expected == state
      unless same_payload && expected_matches
        raise Error.new("state_mismatch", error_url: recovered_error_url(consumed_data) || error_url)
      end

      validate_expiration!(consumed_data)
      consumed_data
    end

    def validate_expiration!(data)
      expires_at = data["expiresAt"].to_i
      return data unless expires_at.positive? && expires_at < Time.now.to_i

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
