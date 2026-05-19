# frozen_string_literal: true

module BetterAuth
  module Plugins
    SCIM_ERROR_SCHEMA = "urn:ietf:params:scim:api:messages:2.0:Error"
    SCIM_LIST_RESPONSE_SCHEMA = "urn:ietf:params:scim:api:messages:2.0:ListResponse"
    SCIM_USER_SCHEMA_ID = "urn:ietf:params:scim:schemas:core:2.0:User"
    SCIM_SUPPORTED_MEDIA_TYPES = ["application/json", "application/scim+json"].freeze

    module_function

    def scim_hidden_metadata(summary, allowed_media_types)
      {
        hide: true,
        allowed_media_types: allowed_media_types,
        openapi: {
          summary: summary,
          responses: scim_openapi_responses
        }
      }
    end

    def scim_openapi_metadata(summary)
      {
        openapi: {
          summary: summary,
          responses: scim_openapi_responses
        }
      }
    end

    def scim_generate_token_openapi_metadata
      {
        openapi: {
          summary: "Generates a new SCIM token for the given provider",
          requestBody: OpenAPI.json_request_body(
            OpenAPI.object_schema(
              {
                provider_id: {type: "string", description: "SCIM provider identifier"},
                organization_id: {type: "string", description: "Organization ID to restrict the SCIM token to"}
              },
              required: ["provider_id"]
            )
          ),
          responses: scim_openapi_responses.merge(
            "201" => OpenAPI.json_response(
              "SCIM token generated",
              OpenAPI.object_schema({scimToken: {type: "string"}}, required: ["scimToken"])
            )
          )
        }
      }
    end

    def scim_delete_provider_openapi_metadata
      {
        openapi: {
          summary: "Delete SCIM provider connection.",
          requestBody: OpenAPI.json_request_body(
            OpenAPI.object_schema(
              {
                provider_id: {type: "string", description: "SCIM provider identifier"}
              },
              required: ["provider_id"]
            )
          ),
          responses: scim_openapi_responses.merge(
            "200" => OpenAPI.json_response("SCIM provider connection deleted", OpenAPI.success_response_schema)
          )
        }
      }
    end

    def scim_openapi_responses
      {
        "200" => {description: "Success"},
        "400" => {description: "Bad Request"},
        "401" => {description: "Unauthorized"},
        "403" => {description: "Forbidden"},
        "404" => {description: "Not Found"}
      }
    end
  end
end
