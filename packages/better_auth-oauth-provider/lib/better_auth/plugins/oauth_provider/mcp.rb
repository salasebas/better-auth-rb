# frozen_string_literal: true

module BetterAuth
  module Plugins
    module OAuthProvider
      module MCP
        module_function

        def www_authenticate(resource, resource_metadata_mappings: {})
          Array(resource).map do |value|
            metadata_url = resource_metadata_url(value, resource_metadata_mappings)
            %(Bearer resource_metadata="#{metadata_url}")
          end.join(", ")
        end

        def resource_metadata_url(resource, mappings = {})
          value = resource.to_s
          uri = URI.parse(value)
          if uri.scheme && uri.host
            path = uri.path.to_s.end_with?("/") ? uri.path.to_s.delete_suffix("/") : uri.path.to_s
            return "#{resource_origin(uri)}/.well-known/oauth-protected-resource#{path}"
          end

          mapped = OAuthProtocol.stringify_keys(mappings || {})[value] || mappings[value.to_sym]
          raise APIError.new("INTERNAL_SERVER_ERROR", message: "missing resource_metadata mapping for #{value}") if mapped.to_s.empty?

          mapped
        rescue URI::InvalidURIError
          mapped = OAuthProtocol.stringify_keys(mappings || {})[value] || mappings[value.to_sym]
          raise APIError.new("INTERNAL_SERVER_ERROR", message: "missing resource_metadata mapping for #{value}") if mapped.to_s.empty?

          mapped
        end

        def resource_origin(uri)
          default_port = (uri.scheme == "http" && uri.port == 80) || (uri.scheme == "https" && uri.port == 443)
          port = default_port ? "" : ":#{uri.port}"
          "#{uri.scheme}://#{uri.host}#{port}"
        end

        def handle_mcp_errors(error, resource, resource_metadata_mappings: {})
          raise error unless error.is_a?(APIError) && error.status_code == 401

          raise APIError.new(
            "UNAUTHORIZED",
            message: error.message,
            headers: {"WWW-Authenticate" => www_authenticate(resource, resource_metadata_mappings: resource_metadata_mappings)}
          )
        end

        def mcp_handler_with_verifier(verify_options:, resource_metadata_mappings: {}, ctx: nil, scopes: nil, jwks_url: nil, remote_verify: nil, &handler)
          audience = verify_options[:audience] || verify_options["audience"]
          mcp_handler(
            resource: audience,
            resource_metadata_mappings: resource_metadata_mappings,
            verifier: lambda do |token|
              ClientResource.verify_access_token(
                token,
                verify_options: verify_options,
                scopes: scopes,
                jwks_url: jwks_url,
                remote_verify: remote_verify,
                ctx: ctx,
                resource: audience,
                resource_metadata_mappings: resource_metadata_mappings
              )
            end,
            &handler
          )
        end

        def mcp_handler(resource:, verifier:, resource_metadata_mappings: {}, &handler)
          lambda do |request|
            authorization = request.respond_to?(:headers) ? request.headers["authorization"] : nil
            token = authorization.to_s.delete_prefix("Bearer ").strip
            raise APIError.new("UNAUTHORIZED", message: "missing authorization header") if token.empty?

            jwt = verifier.call(token)
            handler.call(request, jwt)
          rescue APIError => error
            handle_mcp_errors(error, resource, resource_metadata_mappings: resource_metadata_mappings)
          rescue ::JWT::DecodeError
            handle_mcp_errors(APIError.new("UNAUTHORIZED", message: "invalid token"), resource, resource_metadata_mappings: resource_metadata_mappings)
          end
        end
      end
    end
  end
end
