# frozen_string_literal: true

require "json"
require_relative "mcp/config"
require_relative "mcp/metadata"
require_relative "mcp/schema"
require_relative "mcp/registration"
require_relative "mcp/authorization"
require_relative "mcp/consent"
require_relative "mcp/token"
require_relative "mcp/userinfo"
require_relative "mcp/resource_handler"
require_relative "mcp/legacy_aliases"

module BetterAuth
  module Plugins
    module MCP
      module_function

      def with_mcp_auth(app, resource_metadata_url:, auth: nil, resource_metadata_mappings: {})
        ResourceHandler.with_mcp_auth(
          app,
          resource_metadata_url: resource_metadata_url,
          auth: auth,
          resource_metadata_mappings: resource_metadata_mappings
        )
      end
    end

    module_function

    def mcp(options = {})
      config = MCP.normalize_config(options)
      Plugin.new(
        id: "mcp",
        endpoints: mcp_endpoints(config),
        hooks: {after: [{matcher: ->(_ctx) { true }, handler: ->(ctx) { MCP.restore_login_prompt(ctx, config) }}]},
        schema: MCP.schema,
        options: config
      )
    end

    def mcp_endpoints(config)
      {
        get_mcp_o_auth_config: mcp_oauth_config_endpoint(config),
        get_mcp_protected_resource: mcp_protected_resource_endpoint(config),
        mcp_register: mcp_register_endpoint(config),
        legacy_mcp_register: MCP.legacy_register_endpoint(config),
        mcp_o_auth_authorize: mcp_authorize_endpoint(config),
        legacy_mcp_o_auth_authorize: MCP.legacy_authorize_endpoint(config),
        o_auth_consent: mcp_consent_endpoint(config),
        mcp_o_auth_token: mcp_token_endpoint(config),
        legacy_mcp_o_auth_token: MCP.legacy_token_endpoint(config),
        mcp_o_auth_user_info: mcp_userinfo_endpoint(config),
        legacy_mcp_o_auth_user_info: MCP.legacy_userinfo_endpoint(config),
        get_mcp_session: mcp_get_session_endpoint(config),
        mcp_jwks: mcp_jwks_endpoint(config),
        legacy_mcp_jwks: MCP.legacy_jwks_endpoint(config),
        mcp_o_auth_introspect: mcp_introspect_endpoint(config),
        mcp_o_auth_revoke: mcp_revoke_endpoint(config)
      }
    end

    def mcp_oauth_config_endpoint(config)
      Endpoint.new(path: "/.well-known/oauth-authorization-server", method: "GET", metadata: {hide: true}) do |ctx|
        ctx.json(MCP.oauth_metadata(ctx, config))
      end
    end

    def mcp_protected_resource_endpoint(config)
      Endpoint.new(path: "/.well-known/oauth-protected-resource", method: "GET", metadata: {hide: true}) do |ctx|
        ctx.json(MCP.protected_resource_metadata(ctx, config))
      end
    end

    def mcp_register_endpoint(config)
      Endpoint.new(path: "/oauth2/register", method: "POST", metadata: mcp_openapi("registerMcpClient", "Register an OAuth2 application", "OAuth2 application registered successfully", mcp_client_schema)) do |ctx|
        ctx.json(MCP.register_client(ctx, config), status: 201, headers: MCP.no_store_headers)
      end
    end

    def mcp_authorize_endpoint(config)
      Endpoint.new(path: "/oauth2/authorize", method: "GET", metadata: mcp_openapi("mcpOAuthAuthorize", "Authorize an OAuth2 request using MCP", "Authorization response generated successfully", {type: "object", additionalProperties: true})) do |ctx|
        MCP.authorize(ctx, config)
      end
    end

    def mcp_consent_endpoint(config)
      Endpoint.new(path: "/oauth2/consent", method: "POST", metadata: mcp_openapi("mcpOAuthConsent", "Handle MCP OAuth2 consent", "OAuth2 consent handled successfully", {type: "object", additionalProperties: true})) do |ctx|
        ctx.json(MCP.consent(ctx, config))
      end
    end

    def mcp_token_endpoint(config)
      Endpoint.new(
        path: "/oauth2/token",
        method: "POST",
        metadata: mcp_openapi("mcpOAuthToken", "Exchange OAuth2 code for MCP tokens", "OAuth2 tokens issued successfully", mcp_token_response_schema).merge(allowed_media_types: ["application/x-www-form-urlencoded", "application/json"])
      ) do |ctx|
        ctx.json(MCP.token(ctx, config), headers: MCP.no_store_headers)
      end
    end

    def mcp_userinfo_endpoint(config)
      Endpoint.new(path: "/oauth2/userinfo", method: "GET", metadata: mcp_openapi("mcpOAuthUserinfo", "Get MCP OAuth2 user information", "User information retrieved successfully", mcp_userinfo_schema)) do |ctx|
        ctx.json(MCP.userinfo(ctx, config))
      end
    end

    def mcp_get_session_endpoint(config)
      Endpoint.new(path: "/mcp/get-session", method: "GET", metadata: mcp_openapi("getMcpSession", "Get the MCP session", "MCP session retrieved successfully", {type: ["object", "null"]})) do |ctx|
        ctx.json(MCP.session_from_token(ctx, config))
      end
    end

    def mcp_jwks_endpoint(config)
      Endpoint.new(path: "/oauth2/jwks", method: "GET", metadata: mcp_openapi("getMcpJSONWebKeySet", "Get the MCP JSON Web Key Set", "JSON Web Key Set retrieved successfully", mcp_jwks_response_schema)) do |ctx|
        ctx.json(MCP.jwks(ctx, config))
      end
    end

    def mcp_introspect_endpoint(config)
      Endpoint.new(
        path: "/oauth2/introspect",
        method: "POST",
        metadata: mcp_openapi("mcpOAuthIntrospect", "Introspect an MCP OAuth2 token", "OAuth2 token introspection result", mcp_introspection_schema).merge(allowed_media_types: ["application/x-www-form-urlencoded", "application/json"])
      ) do |ctx|
        ctx.json(MCP.introspect(ctx, config))
      end
    end

    def mcp_revoke_endpoint(config)
      Endpoint.new(
        path: "/oauth2/revoke",
        method: "POST",
        metadata: mcp_openapi("mcpOAuthRevoke", "Revoke an MCP OAuth2 token", "OAuth2 token revoked successfully", OpenAPI.object_schema({revoked: {type: "boolean"}}, required: ["revoked"])).merge(allowed_media_types: ["application/x-www-form-urlencoded", "application/json"])
      ) do |ctx|
        ctx.json(MCP.revoke(ctx, config))
      end
    end

    def mcp_openapi(operation_id, description, response_description, response_schema)
      {
        openapi: {
          operationId: operation_id,
          description: description,
          requestBody: mcp_request_body_for(operation_id),
          responses: {
            "200" => OpenAPI.json_response(response_description, response_schema)
          }
        }
      }
    end

    def mcp_request_body_for(operation_id)
      schema = case operation_id
      when "registerMcpClient", "legacyRegisterMcpClient"
        OpenAPI.object_schema(
          {
            redirect_uris: {type: "array", items: {type: "string", format: "uri"}},
            client_name: {type: "string"},
            client_uri: {type: "string", format: "uri"},
            logo_uri: {type: "string", format: "uri"},
            grant_types: {type: "array", items: {type: "string"}},
            response_types: {type: "array", items: {type: "string"}},
            scope: {type: "string"},
            contacts: {type: "array", items: {type: "string"}},
            metadata: {type: "object", additionalProperties: true}
          },
          required: ["redirect_uris"]
        )
      when "mcpOAuthConsent"
        OpenAPI.object_schema({consent_code: {type: "string"}, accept: {type: "boolean"}, scope: {type: "string"}, scopes: {type: "array", items: {type: "string"}}}, required: ["consent_code"])
      when "mcpOAuthToken", "legacyMcpOAuthToken"
        OpenAPI.object_schema(
          {
            grant_type: {type: "string", enum: [OAuthProtocol::AUTH_CODE_GRANT, OAuthProtocol::REFRESH_GRANT]},
            code: {type: "string"},
            redirect_uri: {type: "string", format: "uri"},
            code_verifier: {type: "string"},
            client_id: {type: "string"},
            client_secret: {type: "string"},
            refresh_token: {type: "string"},
            scope: {type: "string"},
            resource: {oneOf: [{type: "string"}, {type: "array", items: {type: "string"}}]}
          },
          required: ["grant_type"]
        )
      when "mcpOAuthIntrospect", "mcpOAuthRevoke"
        OpenAPI.object_schema({token: {type: "string"}, token_type_hint: {type: "string", enum: ["access_token", "refresh_token"]}}, required: ["token"])
      end
      schema ? OpenAPI.json_request_body(schema) : nil
    end

    def mcp_client_schema
      OpenAPI.object_schema(
        {
          clientId: {type: "string"},
          clientSecret: {type: ["string", "null"]},
          name: {type: ["string", "null"]},
          redirectUris: {type: "array", items: {type: "string"}}
        },
        required: ["clientId"]
      )
    end

    def mcp_token_response_schema
      OpenAPI.object_schema(
        {
          access_token: {type: "string"},
          token_type: {type: "string"},
          expires_in: {type: "number"},
          refresh_token: {type: ["string", "null"]},
          scope: {type: ["string", "null"]}
        },
        required: ["access_token", "token_type", "expires_in"]
      )
    end

    def mcp_userinfo_schema
      OpenAPI.object_schema(
        {
          sub: {type: "string"},
          email: {type: ["string", "null"]},
          email_verified: {type: ["boolean", "null"]},
          name: {type: ["string", "null"]}
        },
        required: ["sub"]
      )
    end

    def mcp_jwks_response_schema
      OpenAPI.object_schema(
        {keys: {type: "array", items: {type: "object"}}},
        required: ["keys"]
      )
    end

    def mcp_introspection_schema
      OpenAPI.object_schema(
        {
          active: {type: "boolean"},
          client_id: {type: ["string", "null"]},
          scope: {type: ["string", "null"]},
          sub: {type: ["string", "null"]},
          iss: {type: ["string", "null"]},
          iat: {type: ["number", "null"]},
          exp: {type: ["number", "null"]},
          sid: {type: ["string", "null"]},
          aud: {type: ["string", "array", "null"], items: {type: "string"}}
        },
        required: ["active"]
      )
    end
  end
end
