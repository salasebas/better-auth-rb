# frozen_string_literal: true

require "json"
require "time"
require "uri"

module BetterAuth
  module Plugins
    module OAuthProtocol
      module_function

      def issuer(ctx)
        origin_for(ctx.context.canonical_base_url)
      end

      def origin_for(url)
        uri = URI.parse(url.to_s)
        port = uri.port
        default_port = (uri.scheme == "http" && port == 80) || (uri.scheme == "https" && port == 443)
        default_port ? "#{uri.scheme}://#{uri.host}" : "#{uri.scheme}://#{uri.host}:#{port}"
      end

      def validate_redirect_uri!(client, redirect_uri)
        validate_safe_url!(redirect_uri, field: "redirect_uri")
        redirects = client_redirect_uris(client)
        return if redirects.include?(redirect_uri.to_s)
        return if loopback_redirect_match?(redirects, redirect_uri)

        raise APIError.new("BAD_REQUEST", message: "invalid redirect_uri")
      end

      def loopback_redirect_match?(redirects, redirect_uri)
        requested = URI.parse(redirect_uri.to_s)
        return false unless ["http", "https"].include?(requested.scheme)
        requested_host = requested.hostname || requested.host
        return false unless loopback_host?(requested_host)

        redirects.any? do |allowed|
          allowed_uri = URI.parse(allowed.to_s)
          allowed_host = allowed_uri.hostname || allowed_uri.host
          allowed_uri.scheme == requested.scheme &&
            loopback_host?(allowed_host) &&
            allowed_host == requested_host &&
            allowed_uri.path == requested.path &&
            allowed_uri.query == requested.query
        rescue URI::InvalidURIError
          false
        end
      rescue URI::InvalidURIError
        false
      end

      def loopback_host?(host)
        ["127.0.0.1", "::1"].include?(host.to_s)
      end

      def store_code(internal_adapter, code:, client_id:, redirect_uri:, session:, scopes:, code_challenge: nil, code_challenge_method: nil, nonce: nil, reference_id: nil, auth_time: nil, expires_in: 600, store_tokens: "hashed")
        stored_code = get_stored_token(store_tokens, code, "authorization_code")
        expires_at = Time.now + expires_in.to_i
        data = {
          client_id: client_id,
          redirect_uri: redirect_uri,
          session: session,
          scopes: parse_scopes(scopes),
          code_challenge: code_challenge,
          code_challenge_method: code_challenge_method,
          nonce: nonce,
          reference_id: reference_id,
          auth_time: auth_time || session_auth_time(session),
          expires_at: expires_at.iso8601(6)
        }
        internal_adapter.create_verification_value(identifier: stored_code, value: JSON.generate(data), expiresAt: expires_at)
      end

      def validate_authorize_pkce(client, scopes, code_challenge, code_challenge_method)
        method = code_challenge_method.to_s
        return "code_challenge_method must be S256" if !code_challenge.to_s.empty? && method != "S256"

        return nil unless pkce_required?(client, scopes)
        return "PKCE is required" if code_challenge.to_s.empty?
        return "code_challenge_method must be S256" if method != "S256"

        nil
      end
    end
  end
end
