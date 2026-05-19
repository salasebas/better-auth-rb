# frozen_string_literal: true

module BetterAuth
  module APIKey
    module Routes
      ROUTE_NAMES = %i[
        create_api_key
        verify_api_key
        get_api_key
        update_api_key
        delete_api_key
        list_api_keys
        delete_all_expired_api_keys
      ].freeze

      module_function

      def resolve_config(context, config, config_id = nil)
        configurations = config.fetch(:configurations, [config])
        return configurations.find { |entry| default_config_id?(entry[:config_id]) } || configurations.first if config_id.to_s.empty?

        configurations.find { |entry| entry[:config_id].to_s == config_id.to_s } ||
          begin
            default = configurations.find { |entry| default_config_id?(entry[:config_id]) }
            unless default
              context.logger.error(BetterAuth::Plugins::API_KEY_ERROR_CODES["NO_DEFAULT_API_KEY_CONFIGURATION_FOUND"]) if context.respond_to?(:logger) && context.logger.respond_to?(:error)
              raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["NO_DEFAULT_API_KEY_CONFIGURATION_FOUND"])
            end
            default
          end
      end

      def default_config_id?(value)
        value.nil? || value.to_s.empty? || value.to_s == "default"
      end

      def config_id_matches?(record_config_id, expected_config_id)
        return true if default_config_id?(record_config_id) && default_config_id?(expected_config_id)

        record_config_id.to_s == expected_config_id.to_s
      end

      @last_expired_check = nil

      def delete_expired(context, config, bypass_last_check: false, raise_on_error: false)
        return unless config[:storage] == "database" || config[:fallback_to_database]
        unless bypass_last_check
          now = Time.now
          return if @last_expired_check && ((now - @last_expired_check) * 1000) < 10_000

          @last_expired_check = now
        end

        now = Time.now
        context.adapter.delete_many(
          model: BetterAuth::Plugins::API_KEY_TABLE_NAME,
          where: [
            {field: "expiresAt", value: now, operator: "lt"},
            {field: "expiresAt", value: nil, operator: "ne"}
          ]
        )
      rescue => error
        context.logger.error("[API KEY PLUGIN] Failed to delete expired API keys: #{error.message}") if context.respond_to?(:logger) && context.logger.respond_to?(:error)
        raise if raise_on_error
      end

      def schedule_cleanup(ctx, config)
        task = -> { delete_expired(ctx.context, config) }
        if config[:defer_updates] && BetterAuth::APIKey::Utils.background_tasks?(ctx)
          BetterAuth::APIKey::Utils.run_background_task(ctx, "Deferred API key cleanup", task)
        else
          task.call
        end
      end

      def openapi_for(route)
        {
          create_api_key: create_api_key_openapi,
          verify_api_key: verify_api_key_openapi,
          get_api_key: get_api_key_openapi,
          update_api_key: update_api_key_openapi,
          delete_api_key: delete_api_key_openapi,
          list_api_keys: list_api_keys_openapi,
          delete_all_expired_api_keys: delete_all_expired_api_keys_openapi
        }.fetch(route)
      end

      def create_api_key_openapi
        {
          openapi: {
            description: "Create a new API key for a user",
            requestBody: BetterAuth::OpenAPI.json_request_body(api_key_create_body_schema, required: true),
            responses: {
              "200" => BetterAuth::OpenAPI.json_response("API key created successfully", api_key_record_schema(include_secret: true))
            }
          }
        }
      end

      def verify_api_key_openapi
        {
          openapi: {
            description: "Verify and rate-limit an API key",
            requestBody: BetterAuth::OpenAPI.json_request_body(
              BetterAuth::OpenAPI.object_schema(
                {
                  key: {type: "string", description: "The API key to verify"},
                  configId: {type: "string", description: "Configuration ID to use for the lookup"},
                  permissions: api_key_permissions_schema.merge(description: "Permissions required for the request")
                },
                required: ["key"]
              )
            ),
            responses: {
              "200" => BetterAuth::OpenAPI.json_response(
                "API key verification result",
                BetterAuth::OpenAPI.object_schema(
                  {
                    valid: {type: "boolean"},
                    error: {type: ["object", "null"], additionalProperties: true},
                    key: api_key_record_schema(include_secret: false).merge(type: ["object", "null"])
                  },
                  required: ["valid", "error", "key"]
                )
              )
            }
          }
        }
      end

      def get_api_key_openapi
        {
          openapi: {
            description: "Get an API key by ID",
            parameters: [
              BetterAuth::OpenAPI.query_parameter("id", required: true, description: "The API key ID"),
              BetterAuth::OpenAPI.query_parameter("configId", description: "Configuration ID to use for the lookup")
            ],
            responses: {
              "200" => BetterAuth::OpenAPI.json_response("API key retrieved successfully", api_key_record_schema(include_secret: false))
            }
          }
        }
      end

      def update_api_key_openapi
        {
          openapi: {
            description: "Update an existing API key by ID",
            requestBody: BetterAuth::OpenAPI.json_request_body(api_key_update_body_schema, required: true),
            responses: {
              "200" => BetterAuth::OpenAPI.json_response("API key updated successfully", api_key_record_schema(include_secret: false))
            }
          }
        }
      end

      def delete_api_key_openapi
        {
          openapi: {
            description: "Delete an API key by ID",
            requestBody: BetterAuth::OpenAPI.json_request_body(
              BetterAuth::OpenAPI.object_schema(
                {
                  keyId: {type: "string", description: "The API key ID"},
                  configId: {type: "string", description: "Configuration ID to use for the lookup"}
                },
                required: ["keyId"]
              )
            ),
            responses: {
              "200" => BetterAuth::OpenAPI.json_response("API key deleted successfully", BetterAuth::OpenAPI.success_response_schema)
            }
          }
        }
      end

      def list_api_keys_openapi
        {
          openapi: {
            description: "List all API keys for the authenticated user or for a specific organization",
            parameters: [
              BetterAuth::OpenAPI.query_parameter("configId", description: "Filter by configuration ID"),
              BetterAuth::OpenAPI.query_parameter("organizationId", description: "Organization ID to list keys for"),
              BetterAuth::OpenAPI.query_parameter("limit", schema: {type: "number"}, description: "The number of API keys to return"),
              BetterAuth::OpenAPI.query_parameter("offset", schema: {type: "number"}, description: "The offset to start from"),
              BetterAuth::OpenAPI.query_parameter("sortBy", description: "The field to sort by"),
              BetterAuth::OpenAPI.query_parameter("sortDirection", schema: {type: "string", enum: ["asc", "desc"]}, description: "The direction to sort by")
            ],
            responses: {
              "200" => BetterAuth::OpenAPI.json_response(
                "API keys retrieved successfully",
                BetterAuth::OpenAPI.object_schema(
                  {
                    apiKeys: BetterAuth::OpenAPI.array_schema(api_key_record_schema(include_secret: false)),
                    total: {type: "number"},
                    limit: {type: ["number", "null"]},
                    offset: {type: ["number", "null"]}
                  },
                  required: ["apiKeys", "total"]
                )
              )
            }
          }
        }
      end

      def delete_all_expired_api_keys_openapi
        {
          openapi: {
            description: "Delete all expired API keys",
            requestBody: BetterAuth::OpenAPI.empty_request_body,
            responses: {
              "200" => BetterAuth::OpenAPI.json_response(
                "Expired API key cleanup result",
                BetterAuth::OpenAPI.object_schema(
                  {
                    success: {type: "boolean"},
                    error: {type: ["object", "null"], additionalProperties: true}
                  },
                  required: ["success", "error"]
                )
              )
            }
          }
        }
      end

      def api_key_create_body_schema
        BetterAuth::OpenAPI.object_schema(
          {
            configId: {type: "string", description: "The configuration ID to use for the API key"},
            name: {type: "string", description: "Name of the API key"},
            expiresIn: {type: ["number", "null"], description: "Expiration time of the API key in seconds"},
            prefix: {type: "string", description: "Prefix of the API key"},
            remaining: {type: ["number", "null"], description: "Remaining number of requests"},
            metadata: {nullable: true, description: "Metadata associated with the API key"},
            refillAmount: {type: "number", description: "Amount to refill the remaining count"},
            refillInterval: {type: "number", description: "Interval to refill the API key in milliseconds"},
            rateLimitTimeWindow: {type: "number", description: "Rate limit time window in milliseconds"},
            rateLimitMax: {type: "number", description: "Maximum requests allowed within a window"},
            rateLimitEnabled: {type: "boolean", description: "Whether the key has rate limiting enabled"},
            permissions: api_key_permissions_schema.merge(description: "Permissions of the API key"),
            userId: {type: "string", description: "User ID that the API key belongs to"},
            organizationId: {type: "string", description: "Organization ID that the API key belongs to"}
          }
        )
      end

      def api_key_update_body_schema
        BetterAuth::OpenAPI.object_schema(
          api_key_create_body_schema[:properties].merge(
            keyId: {type: "string", description: "The API key ID"},
            enabled: {type: "boolean", description: "Whether the API key is enabled"}
          ).except(:prefix, :organizationId),
          required: ["keyId"]
        )
      end

      def api_key_permissions_schema
        {
          type: "object",
          additionalProperties: {
            type: "array",
            items: {type: "string"}
          }
        }
      end

      def api_key_record_schema(include_secret:)
        properties = {
          id: {type: "string", description: "Unique identifier of the API key"},
          createdAt: {type: "string", format: "date-time", description: "Creation timestamp"},
          updatedAt: {type: "string", format: "date-time", description: "Last update timestamp"},
          name: {type: ["string", "null"], description: "Name of the API key"},
          start: {type: ["string", "null"], description: "Starting characters of the key"},
          prefix: {type: ["string", "null"], description: "Prefix of the API key"},
          enabled: {type: "boolean", description: "Whether the key is enabled"},
          expiresAt: {type: ["string", "null"], format: "date-time", description: "Expiration timestamp"},
          referenceId: {type: "string", description: "ID of the reference owning the key"},
          lastRefillAt: {type: ["string", "null"], format: "date-time", description: "Last refill timestamp"},
          lastRequest: {type: ["string", "null"], format: "date-time", description: "Last request timestamp"},
          metadata: {type: ["object", "null"], additionalProperties: true, description: "Metadata associated with the key"},
          rateLimitMax: {type: ["number", "null"], description: "Maximum requests in time window"},
          rateLimitTimeWindow: {type: ["number", "null"], description: "Rate limit time window in milliseconds"},
          rateLimitEnabled: {type: "boolean", description: "Whether rate limiting is enabled"},
          remaining: {type: ["number", "null"], description: "Remaining number of requests"},
          refillAmount: {type: ["number", "null"], description: "Amount to refill"},
          refillInterval: {type: ["number", "null"], description: "Refill interval in milliseconds"},
          permissions: api_key_permissions_schema.merge(nullable: true, description: "Permissions of the API key"),
          userId: {type: ["string", "null"], description: "ID of the user owning the key"}
        }
        properties[:key] = {type: "string", description: "The full API key"} if include_secret
        BetterAuth::OpenAPI.object_schema(properties)
      end
    end
  end
end
