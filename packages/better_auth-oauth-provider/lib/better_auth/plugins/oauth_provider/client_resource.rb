# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module BetterAuth
  module Plugins
    module OAuthProvider
      module ClientResource
        ID = "oauth-provider-resource-client"

        module_function

        def protected_resource_metadata(overrides = {}, authorization_server: nil, oauth_provider_options: nil, external_scopes: [])
          data = OAuthProtocol.stringify_keys(overrides || {})
          resource = data["resource"] || authorization_server
          raise Error, "missing required resource" if resource.to_s.empty?

          validate_resource_scopes!(data["scopes_supported"], oauth_provider_options, external_scopes)

          response = {resource: resource}
          response[:authorization_servers] = [authorization_server] if authorization_server
          response.merge!(data.transform_keys(&:to_sym))
          response[:resource] = resource
          response
        end

        def verify_access_token(token, verify_options:, scopes: nil, jwks_url: nil, remote_verify: nil, resource_metadata_mappings: nil, ctx: nil, resource: nil)
          audience = verify_options[:audience] || verify_options["audience"]
          issuer = verify_options[:issuer] || verify_options["issuer"]
          raise Error, "please define verify_options.audience" if audience.to_s.empty?
          raise Error, "please define verify_options.issuer" if issuer.to_s.empty?

          token = token.to_s.sub(/\ABearer\s+/i, "").strip
          raise APIError.new("UNAUTHORIZED", message: "missing authorization header") if token.empty?

          payload = if remote_verify && introspection_required?(remote_verify, jwks_url)
            remote_introspect(token, remote_verify, audience: audience, issuer: issuer)
          else
            verify_local_jwt(token, ctx: ctx, jwks_url: jwks_url, audience: audience, issuer: issuer, verify_options: verify_options)
          end

          token_scopes = OAuthProtocol.parse_scopes(payload["scope"] || payload[:scope])
          requested = OAuthProtocol.parse_scopes(scopes)
          unless requested.empty? || requested.all? { |scope| token_scopes.include?(scope) }
            raise APIError.new("FORBIDDEN", message: "insufficient_scope")
          end

          payload
        rescue APIError => error
          OAuthProvider::MCP.handle_mcp_errors(error, resource || audience, resource_metadata_mappings: resource_metadata_mappings || {})
        rescue ::JWT::DecodeError => error
          OAuthProvider::MCP.handle_mcp_errors(
            APIError.new("UNAUTHORIZED", message: error.message),
            resource || audience,
            resource_metadata_mappings: resource_metadata_mappings || {}
          )
        end

        def validate_resource_scopes!(scopes_supported, oauth_provider_options, external_scopes)
          scopes = OAuthProtocol.parse_scopes(scopes_supported)
          return if scopes.empty?

          allowed = OAuthProtocol.parse_scopes(oauth_provider_options && oauth_provider_options[:scopes]) + OAuthProtocol.parse_scopes(external_scopes)
          scopes.each do |scope|
            if scope == "openid"
              raise Error, "Only the Auth Server should utilize the openid scope"
            end
            next if allowed.empty? || allowed.include?(scope)

            raise Error, %(Unsupported scope #{scope}. If external, please add to "externalScopes")
          end
        end

        def verify_local_jwt(token, ctx:, jwks_url:, audience:, issuer:, verify_options:)
          raise Error, "ctx is required for local JWT verification without remote_verify" unless ctx

          payload = OAuthProtocol.verify_oauth_jwt(
            ctx,
            token,
            issuer: issuer,
            hs256_secret: ctx.context.secret
          )
          payload_aud = payload["aud"]
          audiences = payload_aud.is_a?(Array) ? payload_aud : [payload_aud]
          raise ::JWT::DecodeError, "invalid audience" unless audiences.compact.map(&:to_s).include?(audience.to_s)

          payload
        end

        def introspection_required?(remote_verify, jwks_url)
          remote = OAuthProtocol.stringify_keys(remote_verify || {})
          remote["force"] == true || jwks_url.to_s.empty?
        end

        def remote_introspect(token, remote_verify, audience:, issuer:)
          remote = OAuthProtocol.stringify_keys(remote_verify || {})
          uri = URI(remote["introspect_url"] || remote["introspectUrl"])
          request = Net::HTTP::Post.new(uri)
          request.basic_auth(remote["client_id"] || remote["clientId"], remote["client_secret"] || remote["clientSecret"])
          request.set_form_data("token" => token)
          response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
            http.request(request)
          end
          body = JSON.parse(response.body)
          raise APIError.new("UNAUTHORIZED", message: "invalid token") unless body["active"]

          body.merge("aud" => body["aud"] || audience, "iss" => body["iss"] || issuer)
        rescue JSON::ParserError
          raise APIError.new("UNAUTHORIZED", message: "invalid token")
        end
      end
    end
  end
end
