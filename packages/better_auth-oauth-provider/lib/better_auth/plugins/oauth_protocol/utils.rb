# frozen_string_literal: true

require "base64"
require "openssl"
require "time"
require "uri"

module BetterAuth
  module Plugins
    module OAuthProtocol
      AUTH_CODE_GRANT = "authorization_code"
      REFRESH_GRANT = "refresh_token"
      CLIENT_CREDENTIALS_GRANT = "client_credentials"
      CLIENT_SECRET_FIELDS = %w[clientSecret client_secret __providedClientSecret].freeze

      module_function

      def parse_scopes(value)
        case value
        when Array
          value.map(&:to_s).reject(&:empty?)
        else
          value.to_s.split(/\s+/).reject(&:empty?)
        end
      end

      def scope_string(value)
        parse_scopes(value).join(" ")
      end

      def request_body!(value)
        return stringify_keys(value || {}) if value.nil? || value.is_a?(Hash)

        raise APIError.new("BAD_REQUEST", message: "request body must be an object")
      end

      def client_require_pkce(data)
        data = stringify_keys(data || {})
        return data["requirePKCE"] if data.key?("requirePKCE")
        return data["requirePkce"] if data.key?("requirePkce")

        nil
      end

      def find_client(ctx, model, client_id, cached_trusted_clients: nil)
        client_id = client_id.to_s
        if (cached = trusted_client_cache[client_id])
          return cached
        end

        client = ctx.context.adapter.find_one(model: model, where: [{field: "clientId", value: client_id}])
        if client && cached_trusted_clients&.include?(client_id)
          trusted_client_cache[client_id] = client
        end
        client
      end

      def authenticate_client!(ctx, model, store_client_secret: "plain", prefix: {}, require_confidential: false, migrate_legacy_hashed: false)
        body = request_body!(ctx.body || {})
        client_id = body["client_id"]
        client_secret = body["client_secret"]

        authorization = ctx.headers["authorization"]
        auth_method_used = client_secret.to_s.empty? ? nil : "client_secret_post"
        if authorization.to_s.start_with?("Basic ")
          begin
            decoded = Base64.strict_decode64(authorization.delete_prefix("Basic "))
          rescue ArgumentError
            raise APIError.new("BAD_REQUEST", message: "invalid authorization header format", body: {error: "invalid_client", error_description: "invalid authorization header format"})
          end
          unless decoded.include?(":")
            raise APIError.new("BAD_REQUEST", message: "invalid authorization header format", body: {error: "invalid_client", error_description: "invalid authorization header format"})
          end
          client_id, client_secret = decoded.split(":", 2)
          if client_id.to_s.empty? || client_secret.to_s.empty?
            raise APIError.new("BAD_REQUEST", message: "invalid authorization header format", body: {error: "invalid_client", error_description: "invalid authorization header format"})
          end
          auth_method_used = "client_secret_basic"
        end

        client = find_client(ctx, model, client_id)
        raise APIError.new("UNAUTHORIZED", message: "invalid_client") unless client

        client_data = stringify_keys(client)
        raise APIError.new("UNAUTHORIZED", message: "invalid_client") if client_data["disabled"]

        method = client_data["tokenEndpointAuthMethod"] || "client_secret_basic"
        if method == "none"
          raise APIError.new("UNAUTHORIZED", message: "invalid_client") if require_confidential
          raise APIError.new("UNAUTHORIZED", message: "invalid_client") unless client_secret.to_s.empty?
          return client
        end
        expected_method = (method == "client_secret_post") ? "client_secret_post" : "client_secret_basic"
        raise APIError.new("UNAUTHORIZED", message: "invalid_client") unless auth_method_used == expected_method
        client_secret = normalized_client_secret_credential!(client_secret, prefix)
        if client_secret_expired?(client_data["clientSecretExpiresAt"])
          raise APIError.new("UNAUTHORIZED", message: "invalid_client")
        end
        if method != "none"
          stored_secret = client_data["clientSecret"]
          verified = verify_client_secret(ctx, stored_secret, client_secret, store_client_secret)
          if !verified && migrate_legacy_hashed && legacy_hashed_client_secret?(stored_secret) && verify_legacy_hashed_client_secret(stored_secret, client_secret)
            encrypted_secret = store_client_secret_value(ctx, client_secret, "encrypted")
            migrated_client = ctx.context.adapter.update(
              model: model,
              where: [
                {field: "clientId", value: client_data["clientId"]},
                {field: "clientSecret", value: stored_secret}
              ],
              update: {clientSecret: encrypted_secret, updatedAt: Time.now}
            )
            client = if migrated_client
              migrated_client
            else
              current_client = ctx.context.adapter.find_one(model: model, where: [{field: "clientId", value: client_data["clientId"]}])
              current_secret = stringify_keys(current_client || {})["clientSecret"]
              current_client if current_client && verify_client_secret(ctx, current_secret, client_secret, "encrypted")
            end
            raise APIError.new("UNAUTHORIZED", message: "invalid_client") unless client

            trusted_client_cache[client_data["clientId"].to_s] = client if trusted_client_cache.key?(client_data["clientId"].to_s)
            verified = true
          end
          raise APIError.new("UNAUTHORIZED", message: "invalid_client") unless verified
        end

        client.merge("__providedClientSecret" => client_secret)
      end

      def normalized_client_secret_credential!(client_secret, prefix)
        credential = client_secret.to_s
        expected_prefix = token_prefix(prefix, :client_secret)
        return credential if expected_prefix.empty?

        unless credential.start_with?(expected_prefix)
          raise APIError.new("UNAUTHORIZED", message: "invalid_client")
        end

        credential.delete_prefix(expected_prefix)
      end

      def legacy_hashed_client_secret?(value)
        value.to_s.match?(/\A[A-Za-z0-9_-]{43}\z/)
      end

      def verify_legacy_hashed_client_secret(stored_secret, provided_secret)
        expected = Crypto.sha256(provided_secret, encoding: :base64url)
        Crypto.constant_time_compare(expected, stored_secret.to_s)
      end

      def client_secret_expired?(value)
        return false if value.nil? || value.to_i == 0

        seconds = timestamp_seconds(value)
        seconds && seconds <= Time.now.to_i
      end

      def pkce_required?(client, scopes)
        data = stringify_keys(client)
        return true if data["public"] || data["tokenEndpointAuthMethod"] == "none" || ["native", "user-agent-based"].include?(data["type"])
        return true if parse_scopes(scopes).include?("offline_access")
        require_pkce = client_require_pkce(data)
        return require_pkce unless require_pkce.nil?

        true
      end

      def schema_model?(ctx, model)
        Schema.auth_tables(ctx.context.options).key?(model.to_s)
      end

      def apply_prefix(value, prefix, kind)
        "#{token_prefix(prefix, kind)}#{value}"
      end

      def trusted_client_cache
        @trusted_client_cache ||= {}
      end

      def strip_prefix(value, prefix, kind)
        token = value.to_s
        expected = token_prefix(prefix, kind)
        return token if expected.empty?
        return token.delete_prefix(expected) if token.start_with?(expected)

        nil
      end

      def token_prefix(prefix, kind)
        data = stringify_keys(prefix || {})
        case kind
        when :access_token
          data["opaque_access_token"] || data["opaqueAccessToken"] || "ba_at_"
        when :refresh_token
          data["refresh_token"] || data["refreshToken"] || "ba_rt_"
        when :client_secret
          data["client_secret"] || data["clientSecret"] || ""
        else
          ""
        end
      end

      def jwt_plugin_options(ctx)
        plugin = ctx.context.options.plugins.find { |entry| entry.id == "jwt" }
        plugin&.options
      end

      def oauth_jwt_config(ctx, issuer:, audience:)
        options = jwt_plugin_options(ctx)
        return nil unless options

        BetterAuth::Plugins.deep_merge(options, jwt: {issuer: issuer, audience: audience})
      end

      def subject_identifier(user_id, client, pairwise_secret)
        data = stringify_keys(client)
        return user_id unless data["subjectType"] == "pairwise" && pairwise_secret && user_id

        OpenSSL::HMAC.hexdigest("SHA256", pairwise_secret.to_s, "#{sector_identifier(data)}.#{user_id}")
      end

      def sector_identifier(client)
        data = stringify_keys(client)
        uri = client_redirect_uris(data).first
        raise APIError.new("BAD_REQUEST", message: "pairwise subject_type requires redirect_uris") if uri.to_s.empty?

        URI.parse(uri.to_s).host || data["clientId"]
      rescue URI::InvalidURIError
        data["clientId"]
      end

      def session_auth_time(session)
        data = stringify_keys(session || {})
        session_data = stringify_keys(data["session"] || data[:session] || data)
        session_data["createdAt"] || session_data["created_at"]
      end

      def timestamp_seconds(value)
        if value.is_a?(Numeric)
          return nil unless value.finite?
          return nil if value.abs > 8_640_000_000_000_000

          return (value / 1000.0).floor if value.abs >= 100_000_000_000

          return value.to_i
        end
        if value.is_a?(String) && value.match?(/\A[-+]?(?:\d+(?:\.\d+)?|\.\d+)(?:e[-+]?\d+)?\z/i)
          numeric = value.to_f
          return nil unless numeric.finite?
          return nil if numeric.abs > 8_640_000_000_000_000

          return (numeric / 1000.0).floor if numeric.abs >= 100_000_000_000

          return numeric.to_i
        end
        return timestamp_seconds(value.to_i) if value.respond_to?(:to_i) && !value.is_a?(String)

        Time.parse(value.to_s).to_i
      rescue ArgumentError, TypeError, FloatDomainError
        nil
      end

      def store_client_secret_value(ctx, secret, mode)
        mode = normalize_secret_storage_mode(mode)
        return Crypto.sha256(secret, encoding: :base64url) if mode == "hashed"
        return Crypto.symmetric_encrypt(key: ctx.context.secret_config, data: secret) if mode == "encrypted"

        if mode.is_a?(Hash)
          return mode[:hash].call(secret) if mode[:hash].respond_to?(:call)
          return mode[:encrypt].call(secret) if mode[:encrypt].respond_to?(:call)
        end

        secret
      end

      def store_token_value(storage_method, token, type)
        case storage_method
        when "hashed", :hashed
          Crypto.sha256(token.to_s, encoding: :base64url)
        else
          mode = normalize_secret_storage_mode(storage_method)
          return mode[:hash].call(token.to_s, type) if mode.is_a?(Hash) && mode[:hash].respond_to?(:call)

          raise Error, "storeToken: unsupported storageMethod type '#{storage_method}'"
        end
      end

      def get_stored_token(storage_method, token, type)
        store_token_value(storage_method, token, type)
      end

      def verify_client_secret(ctx, stored_secret, provided_secret, mode)
        mode = normalize_secret_storage_mode(mode)
        return Crypto.constant_time_compare(Crypto.sha256(provided_secret, encoding: :base64url), stored_secret.to_s) if mode == "hashed"
        if mode == "encrypted"
          begin
            decrypted = Crypto.symmetric_decrypt(key: ctx.context.secret_config, data: stored_secret)
            return Crypto.constant_time_compare(decrypted.to_s, provided_secret.to_s)
          rescue Error, ArgumentError
            return false
          end
        end

        if mode.is_a?(Hash)
          return !!mode[:verify].call(provided_secret, stored_secret) if mode[:verify].respond_to?(:call)
          return Crypto.constant_time_compare(mode[:hash].call(provided_secret).to_s, stored_secret.to_s) if mode[:hash].respond_to?(:call)
          return Crypto.constant_time_compare(mode[:decrypt].call(stored_secret).to_s, provided_secret.to_s) if mode[:decrypt].respond_to?(:call)
        end

        Crypto.constant_time_compare(stored_secret.to_s, provided_secret.to_s)
      end

      def decrypt_stored_client_secret(ctx, stored_secret, mode)
        mode = normalize_secret_storage_mode(mode)
        if mode == "encrypted"
          begin
            return Crypto.symmetric_decrypt(key: ctx.context.secret_config, data: stored_secret)
          rescue Error, ArgumentError
            return nil
          end
        end
        return mode[:decrypt].call(stored_secret) if mode.is_a?(Hash) && mode[:decrypt].respond_to?(:call)
        return stored_secret.to_s if mode == "plain"

        nil
      end

      def redact_client_secret_fields(client)
        stringify_keys(client || {}).except(*CLIENT_SECRET_FIELDS)
      end

      def scrub_token_record_client!(record)
        return record unless record.is_a?(Hash)

        client = record["client"] || record[:client]
        return record unless client.is_a?(Hash)

        record.delete(:client)
        record["client"] = redact_client_secret_fields(client)
        record
      end

      def scrub_client_secret_snapshots!(store)
        return store unless store.respond_to?(:[])

        [:tokens, :refresh_tokens].each do |kind|
          records = store[kind] || store[kind.to_s]
          next unless records.respond_to?(:each_value)

          records.each_value { |record| scrub_token_record_client!(record) }
        end
        store
      end

      def normalize_secret_storage_mode(mode)
        return stringify_keys(mode).transform_keys(&:to_sym) if mode.is_a?(Hash)

        mode.to_s
      end

      def stores
        {
          tokens: {},
          refresh_tokens: {},
          consents: {}
        }
      end
    end
  end
end
