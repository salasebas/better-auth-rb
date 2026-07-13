# frozen_string_literal: true

require "base64"
require "json"

module BetterAuth
  module Plugins
    module OAuthProvider
      module Utils
        module_function

        def get_oauth_provider_plugin(ctx)
          ctx.get_plugin("oauth-provider")
        end

        def get_jwt_plugin(ctx)
          plugin = ctx.get_plugin("jwt")
          raise Error, "jwt_config" unless plugin

          plugin
        end

        def normalize_timestamp_value(value)
          return nil if value.nil?

          seconds = OAuthProtocol.timestamp_seconds(value)
          seconds ? Time.at(seconds) : nil
        end

        def resolve_session_auth_time(value)
          normalize_timestamp_value(OAuthProtocol.session_auth_time(value))
        end

        def verify_oauth_query_params(oauth_query, secret)
          return false if oauth_query.to_s.empty? || oauth_query.to_s.include?("#")

          pairs = URI.decode_www_form(oauth_query.to_s)
          signatures = oauth_pairs_matching(pairs, "sig").map(&:last)
          unsigned_pairs = oauth_pairs_excluding(pairs, "sig")
          signed_names = oauth_pairs_matching(unsigned_pairs, "ba_param").map(&:last)
          payload_pairs = oauth_pairs_excluding(unsigned_pairs, "ba_param")
          exp_values = oauth_pairs_matching(payload_pairs, "exp").map(&:last)
          duplicate_reserved_names = payload_pairs.group_by(&:first).any? do |key, entries|
            %w[exp ba_iat ba_pl].include?(key) && entries.length != 1
          end
          names_valid = signed_names.any? && signed_names.uniq.length == signed_names.length &&
            signed_names.sort == (payload_pairs.map(&:first) + ["ba_param"]).uniq.sort &&
            payload_pairs.all? { |key, _value| signed_names.include?(key) }
          unsigned = URI.encode_www_form(unsigned_pairs.sort_by { |key, value| [key, value] })

          signatures.length == 1 && exp_values.length == 1 && !duplicate_reserved_names && names_valid &&
            exp_values.first.to_i >= Time.now.to_i &&
            Crypto.verify_hmac_signature(unsigned, signatures.first, secret, encoding: :base64url)
        rescue ArgumentError
          false
        end

        def parse_client_metadata(metadata)
          return nil if metadata.nil? || metadata == ""
          return OAuthProtocol.stringify_keys(metadata) if metadata.is_a?(Hash)

          OAuthProtocol.stringify_keys(JSON.parse(metadata.to_s))
        end

        def oauth_pairs_matching(pairs, name)
          pairs.each_with_object([]) { |pair, result| result << pair if pair.first == name }
        end

        def oauth_pairs_excluding(pairs, name)
          pairs.each_with_object([]) { |pair, result| result << pair unless pair.first == name }
        end

        def parse_prompt(prompt)
          OAuthProtocol.parse_scopes(prompt).select do |value|
            Types::OAuth::PROMPTS.include?(value)
          end.uniq
        end

        def basic_to_client_credentials(authorization)
          return nil unless authorization.to_s.start_with?("Basic ")

          decoded = Base64.decode64(authorization.to_s.delete_prefix("Basic "))
          id, secret = decoded.split(":", 2)
          if id.to_s.empty? || secret.to_s.empty?
            raise APIError.new(
              "BAD_REQUEST",
              message: "invalid authorization header format",
              body: {error: "invalid_client", error_description: "invalid authorization header format"}
            )
          end

          {client_id: id, client_secret: secret}
        rescue ArgumentError
          raise APIError.new(
            "BAD_REQUEST",
            message: "invalid authorization header format",
            body: {error: "invalid_client", error_description: "invalid authorization header format"}
          )
        end

        def store_token(token, storage_method: "hashed")
          case storage_method
          when "hashed", :hashed
            Crypto.sha256(token.to_s, encoding: :base64url)
          else
            if storage_method.is_a?(Hash) && storage_method[:hash].respond_to?(:call)
              storage_method[:hash].call(token.to_s)
            else
              raise Error, "storeToken: unsupported storageMethod type '#{storage_method}'"
            end
          end
        end

        alias_method :get_stored_token, :store_token

        def store_client_secret(ctx, client_secret, storage_method: "hashed")
          OAuthProtocol.store_client_secret_value(ctx, client_secret, storage_method)
        end
      end
    end
  end
end
