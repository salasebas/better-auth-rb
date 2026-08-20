# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def sso_parse_saml_response(value, config = {}, provider = nil, ctx = nil)
      parser = config.dig(:saml, :parse_response)
      raise APIError.new("BAD_REQUEST", message: "Invalid SAML response") unless parser.respond_to?(:call)

      sso_validate_single_saml_assertion!(value) if sso_base64_xml?(value)
      parsed = parser.call(raw_response: value.to_s, provider: provider, context: ctx)
      normalize_hash(parsed)
    rescue APIError
      raise APIError.new("BAD_REQUEST", message: "Invalid SAML response")
    rescue
      raise APIError.new("BAD_REQUEST", message: "Invalid SAML response")
    end

    def sso_validate_single_saml_assertion!(saml_response)
      xml = Base64.decode64(saml_response.to_s)
      raise APIError.new("BAD_REQUEST", message: "Invalid base64-encoded SAML response") unless xml.include?("<")

      assertions = xml.scan(/<(?:\w+:)?Assertion(?:\s|>|\/)/).length
      encrypted_assertions = xml.scan(/<(?:\w+:)?EncryptedAssertion(?:\s|>|\/)/).length
      total = assertions + encrypted_assertions
      raise APIError.new("BAD_REQUEST", message: "SAML response contains no assertions") if total.zero?
      if total > 1
        raise APIError.new("BAD_REQUEST", message: "SAML response contains #{total} assertions, expected exactly 1")
      end

      true
    rescue APIError
      raise
    rescue
      raise APIError.new("BAD_REQUEST", message: "Invalid base64-encoded SAML response")
    end

    def sso_validate_saml_timestamp!(conditions, config = {}, now: Time.now.utc)
      conditions = normalize_hash(conditions || {})
      not_before = conditions[:not_before] || conditions[:notBefore]
      not_on_or_after = conditions[:not_on_or_after] || conditions[:notOnOrAfter]
      if not_before.to_s.empty? && not_on_or_after.to_s.empty?
        raise APIError.new("BAD_REQUEST", message: "SAML assertion missing required timestamp conditions") if config.dig(:saml, :require_timestamps)

        return true
      end

      clock_skew_seconds = ((config.dig(:saml, :clock_skew) || SSO_DEFAULT_CLOCK_SKEW_MS).to_f / 1000.0)
      parsed_not_before = sso_parse_saml_timestamp(not_before, "SAML assertion has invalid NotBefore timestamp") unless not_before.to_s.empty?
      parsed_not_on_or_after = sso_parse_saml_timestamp(not_on_or_after, "SAML assertion has invalid NotOnOrAfter timestamp") unless not_on_or_after.to_s.empty?

      raise APIError.new("BAD_REQUEST", message: "SAML assertion is not yet valid") if parsed_not_before && now < (parsed_not_before - clock_skew_seconds)
      raise APIError.new("BAD_REQUEST", message: "SAML assertion has expired") if parsed_not_on_or_after && now > (parsed_not_on_or_after + clock_skew_seconds)

      true
    end

    def sso_parse_saml_timestamp(value, error_message)
      Time.parse(value.to_s).utc
    rescue
      raise APIError.new("BAD_REQUEST", message: error_message)
    end

    def sso_saml_timestamp_conditions(assertion)
      assertion = normalize_hash(assertion || {})
      conditions = normalize_hash(assertion[:conditions] || {})
      conditions[:not_before] ||= assertion[:not_before] || assertion[:notBefore]
      conditions[:not_on_or_after] ||= assertion[:not_on_or_after] || assertion[:notOnOrAfter]
      conditions
    end

    def sso_base64_xml?(value)
      Base64.decode64(value.to_s).lstrip.start_with?("<")
    rescue
      false
    end

    def sso_validate_saml_algorithms!(xml, options = {})
      on_deprecated = (options[:on_deprecated] || "warn").to_s
      signature_algorithms = xml.to_s.scan(/SignatureMethod[^>]+Algorithm=["']([^"']+)["']/).flatten.map { |algorithm| sso_normalize_saml_signature_algorithm(algorithm) }
      digest_algorithms = xml.to_s.scan(/DigestMethod[^>]+Algorithm=["']([^"']+)["']/).flatten.map { |algorithm| sso_normalize_saml_digest_algorithm(algorithm) }
      key_encryption_algorithms = xml.to_s.scan(/<[^\/>]*EncryptedKey\b[\s\S]*?EncryptionMethod[^>]+Algorithm=["']([^"']+)["']/).flatten
      data_encryption_algorithms = xml.to_s.scan(/<[^\/>]*EncryptedData\b[\s\S]*?EncryptionMethod[^>]+Algorithm=["']([^"']+)["']/).flatten

      sso_validate_saml_algorithm_group!(
        signature_algorithms,
        allowed: options[:allowed_signature_algorithms]&.map { |algorithm| sso_normalize_saml_signature_algorithm(algorithm) },
        secure: SSO_SAML_SECURE_SIGNATURE_ALGORITHMS,
        deprecated: ["http://www.w3.org/2000/09/xmldsig#rsa-sha1"],
        on_deprecated: on_deprecated,
        label: "signature"
      )
      sso_validate_saml_algorithm_group!(
        digest_algorithms,
        allowed: options[:allowed_digest_algorithms]&.map { |algorithm| sso_normalize_saml_digest_algorithm(algorithm) },
        secure: SSO_SAML_SECURE_DIGEST_ALGORITHMS,
        deprecated: ["http://www.w3.org/2000/09/xmldsig#sha1"],
        on_deprecated: on_deprecated,
        label: "digest"
      )
      sso_validate_saml_algorithm_group!(
        key_encryption_algorithms,
        allowed: options[:allowed_key_encryption_algorithms],
        secure: SSO_SAML_SECURE_KEY_ENCRYPTION_ALGORITHMS,
        deprecated: ["http://www.w3.org/2001/04/xmlenc#rsa-1_5"],
        on_deprecated: on_deprecated,
        label: "key encryption"
      )
      sso_validate_saml_algorithm_group!(
        data_encryption_algorithms,
        allowed: options[:allowed_data_encryption_algorithms],
        secure: SSO_SAML_SECURE_DATA_ENCRYPTION_ALGORITHMS,
        deprecated: ["http://www.w3.org/2001/04/xmlenc#tripledes-cbc"],
        on_deprecated: on_deprecated,
        label: "data encryption"
      )

      true
    end

    def sso_normalize_saml_signature_algorithm(algorithm)
      SSO_SAML_SIGNATURE_ALGORITHMS.fetch(algorithm.to_s.downcase, algorithm.to_s)
    end

    def sso_normalize_saml_digest_algorithm(algorithm)
      SSO_SAML_DIGEST_ALGORITHMS.fetch(algorithm.to_s.downcase, algorithm.to_s)
    end

    def sso_validate_saml_algorithm_group!(algorithms, allowed:, secure:, deprecated:, on_deprecated:, label:)
      algorithms.each do |algorithm|
        if allowed
          next if allowed.include?(algorithm)

          raise APIError.new("BAD_REQUEST", message: "SAML #{label} algorithm not in allow-list: #{algorithm}")
        end

        if deprecated.include?(algorithm)
          raise APIError.new("BAD_REQUEST", message: "SAML response uses deprecated #{label} algorithm: #{algorithm}") if on_deprecated == "reject"
          next
        end
        next if secure.include?(algorithm)

        raise APIError.new("BAD_REQUEST", message: "SAML #{label} algorithm not recognized: #{algorithm}")
      end
    end

    def sso_generate_saml_relay_state(ctx, state_data)
      ttl_ms = 10 * 60 * 1000
      cookie_ttl_seconds = ttl_ms / 1000
      relay_state = BetterAuth::Crypto.random_string(32)
      now_ms = (Time.now.to_f * 1000).to_i
      stored = state_data.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      %w[errorURL newUserURL link requestSignUp].each { |key| stored.delete(key) if stored[key].nil? }
      stored.merge!(
        "codeVerifier" => BetterAuth::Crypto.random_string(128),
        "oauthState" => relay_state,
        "expiresAt" => now_ms + ttl_ms
      )
      if sso_saml_cookie_state_strategy?(ctx)
        cookie = sso_saml_relay_state_cookie(ctx, max_age: cookie_ttl_seconds)
        encrypted = BetterAuth::Crypto.symmetric_encrypt(key: ctx.context.secret_config, data: JSON.generate(stored))
        ctx.set_cookie(cookie.name, encrypted, cookie.attributes)
      else
        cookie = sso_saml_relay_state_cookie(ctx, max_age: cookie_ttl_seconds / 2)
        ctx.context.internal_adapter.create_verification_value(
          identifier: relay_state,
          value: JSON.generate(stored),
          expiresAt: Time.at((now_ms + ttl_ms) / 1000.0)
        )
        ctx.set_signed_cookie(cookie.name, relay_state, ctx.context.secret, cookie.attributes)
      end
      relay_state
    end

    def sso_parse_saml_relay_state(ctx, relay_state)
      state = sso_verify_state(relay_state, ctx.context.secret)
      return state if state

      return nil if relay_state.to_s.empty?

      return sso_parse_saml_relay_state_cookie(ctx, relay_state) if sso_saml_cookie_state_strategy?(ctx)

      verification = ctx.context.internal_adapter.find_verification_value(relay_state)
      return nil unless verification

      parsed = sso_parse_saml_relay_state_data(verification.fetch("value"))
      return nil unless parsed
      return nil if parsed.key?("oauthState") && parsed["oauthState"] != relay_state

      BetterAuth::Cookies.expire_cookie(ctx, sso_saml_relay_state_cookie(ctx))
      consumed = ctx.context.internal_adapter.consume_verification_value(relay_state)
      return nil unless consumed && consumed["value"] == verification["value"]
      return nil if parsed["expiresAt"].to_i <= (Time.now.to_f * 1000).to_i

      parsed
    rescue
      nil
    end

    def sso_parse_saml_relay_state_data(value)
      parsed = JSON.parse(value)
      return nil unless parsed.is_a?(Hash)
      return nil unless parsed["callbackURL"].is_a?(String)
      return nil unless parsed["codeVerifier"].is_a?(String)
      return nil unless parsed["expiresAt"].is_a?(Numeric)
      return nil if parsed.key?("errorURL") && !parsed["errorURL"].is_a?(String)
      return nil if parsed.key?("newUserURL") && !parsed["newUserURL"].is_a?(String)
      return nil if parsed.key?("oauthState") && !parsed["oauthState"].is_a?(String)
      return nil if parsed.key?("requestSignUp") && ![true, false].include?(parsed["requestSignUp"])

      return parsed unless parsed.key?("link")

      link = parsed["link"]
      return nil unless link.is_a?(Hash) && link["email"].is_a?(String) && link.key?("userId")
      return nil if link["userId"].nil?

      parsed["link"] = {"email" => link["email"], "userId" => String(link["userId"])}
      parsed
    rescue ArgumentError, TypeError
      nil
    end

    def sso_parse_saml_relay_state_cookie(ctx, relay_state)
      cookie = sso_saml_relay_state_cookie(ctx)
      encrypted = ctx.get_cookie(cookie.name)
      return nil if encrypted.to_s.empty?

      decrypted = BetterAuth::Crypto.symmetric_decrypt(key: ctx.context.secret_config, data: encrypted)
      parsed = sso_parse_saml_relay_state_data(decrypted)
      return nil unless parsed && parsed["oauthState"] == relay_state

      BetterAuth::Cookies.expire_cookie(ctx, cookie)
      return nil if parsed["expiresAt"].to_i <= (Time.now.to_f * 1000).to_i

      parsed
    end

    def sso_saml_relay_state_cookie(ctx, max_age: nil)
      attributes = max_age ? {max_age: max_age} : {}
      ctx.context.create_auth_cookie("relay_state", attributes)
    end

    def sso_saml_cookie_state_strategy?(ctx)
      ctx.context.options.account[:store_state_strategy].to_s == "cookie"
    end
  end
end
