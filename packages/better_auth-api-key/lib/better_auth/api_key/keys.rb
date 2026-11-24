# frozen_string_literal: true

require "securerandom"

module BetterAuth
  module APIKey
    module Keys
      module_function

      def default_hasher(key)
        BetterAuth::Crypto.sha256(key.to_s, encoding: :base64url)
      end

      def generate(config, prefix)
        generator = config[:custom_key_generator]
        return generator.call({length: config[:default_key_length], prefix: prefix}) if generator.respond_to?(:call)

        alphabet = [*("a".."z"), *("A".."Z")]
        "#{prefix}#{Array.new(config[:default_key_length].to_i) { alphabet[SecureRandom.random_number(alphabet.length)] }.join}"
      end

      def hash(key, config)
        config[:disable_key_hashing] ? key.to_s : default_hasher(key)
      end

      def normalize_body(raw)
        body = BetterAuth::Plugins.normalize_hash(raw)
        return body unless raw.is_a?(Hash)

        metadata_key = raw.key?(:metadata) ? :metadata : ("metadata" if raw.key?("metadata"))
        body[:metadata] = raw[metadata_key] if metadata_key
        body
      end

      def expires_at(body, config)
        if body.key?(:expires_in)
          Time.now + body[:expires_in].to_i unless body[:expires_in].nil?
        elsif config[:key_expiration][:default_expires_in]
          Time.now + config[:key_expiration][:default_expires_in].to_i
        end
      end

      def from_headers(ctx, config)
        getter = config[:custom_api_key_getter]
        return getter.call(ctx) if getter.respond_to?(:call)

        Array(config[:api_key_headers]).each do |header|
          value = ctx.headers[header.to_s.downcase]
          return value if value
        end
        nil
      end
    end
  end
end
