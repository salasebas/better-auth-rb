# frozen_string_literal: true

module BetterAuth
  module Passkey
    module Routes
      module_function

      def openapi_for(route)
        {
          generate_registration_options: generate_registration_options_openapi,
          verify_registration: verify_registration_openapi,
          generate_authentication_options: generate_authentication_options_openapi,
          verify_authentication: verify_authentication_openapi,
          list_passkeys: list_passkeys_openapi,
          delete_passkey: delete_passkey_openapi,
          update_passkey: update_passkey_openapi
        }.fetch(route)
      end

      def generate_registration_options_openapi
        {
          openapi: {
            operationId: "generatePasskeyRegistrationOptions",
            description: "Generate registration options for a new passkey",
            requestBody: BetterAuth::OpenAPI.json_request_body(
              BetterAuth::OpenAPI.object_schema(
                {
                  authenticatorAttachment: {type: "string", enum: ["platform", "cross-platform"], description: "Type of authenticator to use for registration"},
                  name: {type: "string", description: "Optional custom name for the passkey"},
                  context: {type: "string", description: "Optional context for passkey-first registration flows"}
                }
              ),
              required: false
            ),
            responses: {
              "200" => BetterAuth::OpenAPI.json_response("Success", passkey_options_schema)
            }
          }
        }
      end

      def verify_registration_openapi
        {
          openapi: {
            operationId: "passkeyVerifyRegistration",
            description: "Verify registration of a new passkey",
            requestBody: BetterAuth::OpenAPI.json_request_body(
              BetterAuth::OpenAPI.object_schema(
                {
                  response: {type: "object", additionalProperties: true, description: "WebAuthn registration response"},
                  name: {type: "string", description: "Name of the passkey"}
                },
                required: ["response"]
              )
            ),
            responses: {
              "200" => BetterAuth::OpenAPI.json_response("Success", BetterAuth::OpenAPI.ref_schema("Passkey")),
              "400" => {description: "Bad request"}
            }
          }
        }
      end

      def generate_authentication_options_openapi
        {
          openapi: {
            operationId: "passkeyGenerateAuthenticateOptions",
            description: "Generate authentication options for a passkey",
            requestBody: BetterAuth::OpenAPI.empty_request_body,
            responses: {
              "200" => BetterAuth::OpenAPI.json_response("Success", passkey_options_schema)
            }
          }
        }
      end

      def verify_authentication_openapi
        {
          openapi: {
            operationId: "passkeyVerifyAuthentication",
            description: "Verify authentication of a passkey",
            requestBody: BetterAuth::OpenAPI.json_request_body(
              BetterAuth::OpenAPI.object_schema(
                {
                  response: {type: "object", additionalProperties: true, description: "WebAuthn authentication response"}
                },
                required: ["response"]
              )
            ),
            responses: {
              "200" => BetterAuth::OpenAPI.json_response("Success", BetterAuth::OpenAPI.session_response_schema_pair)
            }
          }
        }
      end

      def list_passkeys_openapi
        {
          openapi: {
            description: "List all passkeys for the authenticated user",
            responses: {
              "200" => BetterAuth::OpenAPI.json_response(
                "Passkeys retrieved successfully",
                BetterAuth::OpenAPI.array_schema(BetterAuth::OpenAPI.ref_schema("Passkey"))
              )
            }
          }
        }
      end

      def delete_passkey_openapi
        {
          openapi: {
            description: "Delete a specific passkey",
            requestBody: BetterAuth::OpenAPI.json_request_body(passkey_id_body_schema),
            responses: {
              "200" => BetterAuth::OpenAPI.json_response("Passkey deleted successfully", BetterAuth::OpenAPI.status_response_schema)
            }
          }
        }
      end

      def update_passkey_openapi
        {
          openapi: {
            description: "Update a specific passkey's name",
            requestBody: BetterAuth::OpenAPI.json_request_body(
              BetterAuth::OpenAPI.object_schema(
                {
                  id: {type: "string", description: "The ID of the passkey which will be updated"},
                  name: {type: "string", description: "The new passkey name"}
                },
                required: ["id", "name"]
              )
            ),
            responses: {
              "200" => BetterAuth::OpenAPI.json_response(
                "Passkey updated successfully",
                BetterAuth::OpenAPI.object_schema(
                  {
                    passkey: BetterAuth::OpenAPI.ref_schema("Passkey")
                  },
                  required: ["passkey"]
                )
              )
            }
          }
        }
      end

      def passkey_id_body_schema
        BetterAuth::OpenAPI.object_schema(
          {
            id: {type: "string", description: "The ID of the passkey"}
          },
          required: ["id"]
        )
      end

      def passkey_options_schema
        BetterAuth::OpenAPI.object_schema(
          {
            challenge: {type: "string"},
            rp: {
              type: "object",
              properties: {
                name: {type: "string"},
                id: {type: "string"}
              }
            },
            user: {type: "object", additionalProperties: true},
            timeout: {type: "number"},
            attestation: {type: "string"},
            excludeCredentials: {type: "array", items: {type: "object", additionalProperties: true}},
            allowCredentials: {type: "array", items: {type: "object", additionalProperties: true}},
            userVerification: {type: "string"},
            extensions: {type: "object", additionalProperties: true}
          }
        )
      end
    end
  end
end

require_relative "routes/registration"
require_relative "routes/authentication"
require_relative "routes/management"
