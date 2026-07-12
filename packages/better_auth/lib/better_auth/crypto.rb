# frozen_string_literal: true

require "base64"
require "json"
require "jwt"
require "openssl"
require "securerandom"
require_relative "crypto/jwe"

module BetterAuth
  module Crypto
    ALPHABETIC_ALPHABET = [*"a".."z", *"A".."Z"].freeze
    URL_SAFE_ALPHABET = [*ALPHABETIC_ALPHABET, *"0".."9", "-", "_"].freeze
    MASK_64 = (1 << 64) - 1
    KECCAK_ROUND_CONSTANTS = [
      0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
      0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
      0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
      0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
      0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
      0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
    ].freeze
    KECCAK_ROTATION_OFFSETS = [
      [0, 36, 3, 41, 18],
      [1, 44, 10, 45, 2],
      [62, 6, 43, 15, 61],
      [28, 55, 25, 21, 56],
      [27, 20, 39, 8, 14]
    ].freeze

    module_function

    def random_string(length = 32, alphabet: URL_SAFE_ALPHABET)
      Array.new(length) { alphabet[SecureRandom.random_number(alphabet.length)] }.join
    end

    def uuid
      SecureRandom.uuid
    end

    def sha256(value, encoding: :hex)
      digest = OpenSSL::Digest.digest("SHA256", value.to_s)
      (encoding == :base64url) ? base64url_encode(digest) : digest.unpack1("H*")
    end

    def keccak256(value, encoding: :hex)
      digest = keccak256_bytes(value.to_s.b)
      (encoding == :bytes) ? digest : digest.unpack1("H*")
    end

    def to_checksum_address(address)
      normalized = address.to_s.downcase.delete_prefix("0x")
      hash = keccak256(normalized)

      "0x" + normalized.chars.each_with_index.map do |char, index|
        (hash[index].to_i(16) >= 8) ? char.upcase : char
      end.join
    end

    def hmac_signature(value, secret, encoding: :base64)
      digest = OpenSSL::HMAC.digest("SHA256", secret.to_s, value.to_s)
      (encoding == :base64url) ? base64url_encode(digest) : Base64.strict_encode64(digest)
    end

    def verify_hmac_signature(value, signature, secret, encoding: :base64)
      expected = hmac_signature(value, secret, encoding: encoding)
      constant_time_compare(expected, signature.to_s)
    end

    def constant_time_compare(left, right)
      return false unless left.bytesize == right.bytesize

      OpenSSL.fixed_length_secure_compare(left, right)
    end

    def symmetric_encrypt(key:, data:)
      if key.is_a?(SecretConfig)
        ciphertext = symmetric_encrypt(key: key.current_secret, data: data)
        return "#{SecretConfig::ENVELOPE_PREFIX}#{key.current_version}$#{ciphertext}"
      end

      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.encrypt
      cipher.key = OpenSSL::Digest.digest("SHA256", key.to_s)
      iv = SecureRandom.random_bytes(12)
      cipher.iv = iv
      ciphertext = cipher.update(data.to_s) + cipher.final
      payload = {
        "iv" => base64url_encode(iv),
        "data" => base64url_encode(ciphertext),
        "tag" => base64url_encode(cipher.auth_tag)
      }
      base64url_encode(JSON.generate(payload))
    end

    def symmetric_decrypt(key:, data:)
      if key.is_a?(SecretConfig)
        envelope = parse_envelope(data)
        if envelope
          secret = key.keys[envelope[:version]]
          return nil unless secret

          return symmetric_decrypt(key: secret, data: envelope[:ciphertext])
        end

        return nil unless key.legacy_secret

        return symmetric_decrypt(key: key.legacy_secret, data: data)
      end

      payload = JSON.parse(base64url_decode(data.to_s))
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.decrypt
      cipher.key = OpenSSL::Digest.digest("SHA256", key.to_s)
      cipher.iv = base64url_decode(payload.fetch("iv"))
      cipher.auth_tag = base64url_decode(payload.fetch("tag"))
      cipher.update(base64url_decode(payload.fetch("data"))) + cipher.final
    rescue JSON::ParserError, KeyError, OpenSSL::Cipher::CipherError, ArgumentError
      nil
    end

    def sign_jwt(payload, secret, expires_in: 3600)
      claims = stringify_keys(payload).merge(
        "iat" => Time.now.to_i,
        "exp" => Time.now.to_i + expires_in.to_i
      )
      JWT.encode(claims, secret.to_s, "HS256")
    end

    def verify_jwt(token, secret)
      decoded, = JWT.decode(token.to_s, secret.to_s, true, algorithm: "HS256")
      decoded
    rescue JWT::DecodeError
      nil
    end

    def symmetric_encode_jwt(payload, secret, salt, expires_in: 3600)
      JWE.encode(payload, secret, salt, expires_in: expires_in)
    end

    def symmetric_decode_jwt(token, secret, salt)
      JWE.decode(token, secret, salt)
    end

    def base64url_encode(value)
      Base64.urlsafe_encode64(value.to_s, padding: false)
    end

    def base64url_decode(value)
      Base64.urlsafe_decode64(value.to_s)
    end

    def stringify_keys(value)
      return value.each_with_object({}) { |(key, object_value), result| result[key.to_s] = stringify_keys(object_value) } if value.is_a?(Hash)
      return value.map { |entry| stringify_keys(entry) } if value.is_a?(Array)

      value
    end

    def parse_envelope(data)
      value = data.to_s
      return nil unless value.start_with?(SecretConfig::ENVELOPE_PREFIX)

      rest = value.delete_prefix(SecretConfig::ENVELOPE_PREFIX)
      version, ciphertext = rest.split("$", 2)
      return nil if version.to_s.empty? || ciphertext.to_s.empty?

      {version: SecretConfig.parse_version!(version, source: "encrypted envelope"), ciphertext: ciphertext}
    rescue Error
      nil
    end

    def keccak256_bytes(input)
      rate = 136
      state = Array.new(25, 0)
      padded = input.bytes
      padded << 0x01
      padded << 0 while (padded.length % rate) != rate - 1
      padded << 0x80

      padded.each_slice(rate) do |block|
        block.each_with_index do |byte, index|
          state[index / 8] ^= byte << (8 * (index % 8))
        end
        keccak_permute!(state)
      end

      state.pack("Q<*").byteslice(0, 32)
    end

    def keccak_permute!(state)
      KECCAK_ROUND_CONSTANTS.each do |round_constant|
        columns = Array.new(5) { |x| state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20] }
        deltas = Array.new(5) { |x| columns[(x - 1) % 5] ^ rotate_left_64(columns[(x + 1) % 5], 1) }
        5.times do |x|
          5.times { |y| state[x + (5 * y)] = (state[x + (5 * y)] ^ deltas[x]) & MASK_64 }
        end

        rotated = Array.new(25, 0)
        5.times do |x|
          5.times do |y|
            rotated[y + (5 * ((2 * x + 3 * y) % 5))] =
              rotate_left_64(state[x + (5 * y)], KECCAK_ROTATION_OFFSETS[x][y])
          end
        end

        5.times do |y|
          5.times do |x|
            state[x + (5 * y)] =
              (rotated[x + (5 * y)] ^ ((~rotated[((x + 1) % 5) + (5 * y)]) & rotated[((x + 2) % 5) + (5 * y)])) & MASK_64
          end
        end
        state[0] = (state[0] ^ round_constant) & MASK_64
      end
    end

    def rotate_left_64(value, shift)
      shift %= 64
      return value & MASK_64 if shift.zero?

      ((value << shift) | (value >> (64 - shift))) & MASK_64
    end
  end
end
