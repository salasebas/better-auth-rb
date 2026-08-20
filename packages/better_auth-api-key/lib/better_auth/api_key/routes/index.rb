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
      NO_DEFAULT_CONFIGURATION_LOG_MESSAGE = "No default api-key configuration found. Either provide an api-key configuration with configId 'default' or provide a configuration with no `configId` set."

      module_function

      def resolve_config(context, config, config_id = nil)
        configurations = config.fetch(:configurations, [config])
        unless default_config_id?(config_id)
          selected = configurations.find { |entry| entry[:config_id].to_s == config_id.to_s }
          return selected if selected
        end

        default = configurations.find { |entry| default_config_id?(entry[:config_id]) }
        return default.merge(config_id: "default") if default

        context.logger.error(NO_DEFAULT_CONFIGURATION_LOG_MESSAGE) if context.respond_to?(:logger) && context.logger.respond_to?(:error)
        raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["NO_DEFAULT_API_KEY_CONFIGURATION_FOUND"])
      end

      def default_config_id?(value)
        value.nil? || value == false || value == 0 || value == "" || value.to_s == "default" || (value.respond_to?(:nan?) && value.nan?)
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
              "200" => BetterAuth::OpenAPI.json_response(
                "API key created successfully",
                api_key_openapi_record_schema(include_secret: true, legacy_owner: false)
              )
            }
          }
        }
      end

      def verify_api_key_openapi
        response_schema = BetterAuth::OpenAPI.object_schema(
          {
            valid: {type: "boolean"},
            error: BetterAuth::OpenAPI.object_schema(
              {
                message: {type: "string"},
                code: {type: "string"}
              },
              required: ["message", "code"]
            ).merge(nullable: true),
            key: api_key_public_record_schema.merge(type: ["object", "null"])
          },
          required: ["valid", "error", "key"]
        )
        {
          openapi: {
            description: "Verify and rate-limit an API key",
            requestBody: BetterAuth::OpenAPI.json_request_body(
              BetterAuth::OpenAPI.object_schema(
                {
                  key: {type: "string", description: "The API key to verify"},
                  configId: {type: "string", description: "Configuration ID to use for the lookup"},
                  permissions: api_key_request_permissions_schema.merge(description: "Permissions required for the request")
                },
                required: ["key"]
              )
            ),
            responses: {
              "200" => BetterAuth::OpenAPI.json_response(
                "API key verification result",
                response_schema
              ),
              "401" => BetterAuth::OpenAPI.json_response("API key authentication failed", response_schema),
              "429" => BetterAuth::OpenAPI.json_response("API key usage or rate limit exceeded", response_schema)
            }
          }
        }
      end

      def get_api_key_openapi
        {
          openapi: {
            description: "Retrieve an existing API key by ID",
            parameters: [
              BetterAuth::OpenAPI.query_parameter("id", required: true, description: "The id of the Api Key"),
              BetterAuth::OpenAPI.query_parameter(
                "configId",
                description: "The configuration ID to use for the API key lookup. If not provided, the default configuration will be used."
              )
            ],
            responses: {
              "200" => BetterAuth::OpenAPI.json_response(
                "API key retrieved successfully",
                api_key_openapi_record_schema(include_secret: false, legacy_owner: true)
              )
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
              "200" => BetterAuth::OpenAPI.json_response(
                "API key updated successfully",
                api_key_openapi_record_schema(include_secret: false, legacy_owner: true)
              )
            }
          }
        }
      end

      def delete_api_key_openapi
        {
          openapi: {
            description: "Delete an existing API key",
            requestBody: BetterAuth::OpenAPI.json_request_body(
              BetterAuth::OpenAPI.object_schema(
                {
                  keyId: {type: "string", description: "The id of the API key to delete"}
                },
                required: ["keyId"]
              ),
              required: false
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
              BetterAuth::OpenAPI.query_parameter(
                "configId",
                description: "Filter by configuration ID. If not provided, returns keys from all configurations."
              ),
              BetterAuth::OpenAPI.query_parameter(
                "organizationId",
                description: "Organization ID to list keys for. If provided, returns organization-owned keys. If not provided, returns user-owned keys."
              ),
              BetterAuth::OpenAPI.query_parameter("limit", schema: {type: "number"}, description: "The number of API keys to return"),
              BetterAuth::OpenAPI.query_parameter("offset", schema: {type: "number"}, description: "The offset to start from"),
              BetterAuth::OpenAPI.query_parameter("sortBy", description: "The field to sort by (e.g., createdAt, name, expiresAt)"),
              BetterAuth::OpenAPI.query_parameter("sortDirection", schema: {type: "string", enum: ["asc", "desc"]}, description: "The direction to sort by")
            ],
            responses: {
              "200" => BetterAuth::OpenAPI.json_response(
                "API keys retrieved successfully",
                BetterAuth::OpenAPI.object_schema(
                  {
                    apiKeys: BetterAuth::OpenAPI.array_schema(api_key_openapi_record_schema(include_secret: false, legacy_owner: true)),
                    total: {type: "number", description: "Total number of API keys"},
                    limit: {type: "number", nullable: true, description: "The limit used for pagination"},
                    offset: {type: "number", nullable: true, description: "The offset used for pagination"}
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
            configId: {
              type: "string",
              description: "The configuration ID to use for the API key. If not provided, the default configuration will be used."
            },
            name: {type: "string", description: "Name of the Api Key"},
            expiresIn: {type: ["number", "null"], description: "Expiration time of the Api Key in seconds"},
            prefix: {type: "string", description: "Prefix of the Api Key"},
            remaining: {type: ["number", "null"], description: "Remaining number of requests. Server side only"},
            metadata: {},
            refillAmount: {type: "number", description: "Amount to refill the remaining count of the Api Key. server-only. Eg: 100"},
            refillInterval: {type: "number", description: "Interval to refill the Api Key in milliseconds. server-only. Eg: 1000"},
            rateLimitTimeWindow: {
              type: "number",
              description: "The duration in milliseconds where each request is counted. Once the `maxRequests` is reached, the request will be rejected until the `timeWindow` has passed, at which point the `timeWindow` will be reset. server-only. Eg: 1000"
            },
            rateLimitMax: {
              type: "number",
              description: "Maximum amount of requests allowed within a window. Once the `maxRequests` is reached, the request will be rejected until the `timeWindow` has passed, at which point the `timeWindow` will be reset. server-only. Eg: 100"
            },
            rateLimitEnabled: {type: "boolean", description: "Whether the key has rate limiting enabled. server-only. Eg: true"},
            permissions: api_key_request_permissions_schema.merge(description: "Permissions of the Api Key."),
            userId: {type: "string", description: "User Id of the user that the Api Key belongs to. server-only. Eg: \"user-id\""},
            organizationId: {type: "string", description: "Organization Id of the organization that the Api Key belongs to. Eg: 'org-id'"}
          }
        )
      end

      def api_key_update_body_schema
        BetterAuth::OpenAPI.object_schema(
          {
            configId: {
              type: "string",
              description: "The configuration ID to use for the API key lookup. If not provided, the default configuration will be used."
            },
            keyId: {type: "string", description: "The id of the Api Key"},
            userId: {type: "string", description: "The id of the user which the api key belongs to. server-only. Eg: \"some-user-id\""},
            name: {type: "string", description: "The name of the key"},
            enabled: {type: "boolean", description: "Whether the Api Key is enabled or not"},
            remaining: {type: "number", description: "The number of remaining requests"},
            refillAmount: {type: "number", description: "The refill amount"},
            refillInterval: {type: "number", description: "The refill interval"},
            metadata: {},
            expiresIn: {type: ["number", "null"], description: "Expiration time of the Api Key in seconds"},
            rateLimitEnabled: {type: "boolean", description: "Whether the key has rate limiting enabled."},
            rateLimitTimeWindow: {type: "number", description: "The duration in milliseconds where each request is counted. server-only. Eg: 1000"},
            rateLimitMax: {
              type: "number",
              description: "Maximum amount of requests allowed within a window. Once the `maxRequests` is reached, the request will be rejected until the `timeWindow` has passed, at which point the `timeWindow` will be reset. server-only. Eg: 100"
            },
            permissions: api_key_request_permissions_schema.merge(
              type: ["object", "null"],
              description: "Update the permissions on the API Key. server-only."
            )
          },
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

      def api_key_request_permissions_schema
        api_key_permissions_schema.merge(propertyNames: {type: "string"})
      end

      # v1.7.1's get/list/update OpenAPI blocks still describe the legacy
      # userId/string-permissions shape even though their runtime responses use
      # referenceId and decoded permissions. Preserve both observable contracts.
      def api_key_openapi_record_schema(include_secret:, legacy_owner:)
        return legacy_api_key_openapi_record_schema if legacy_owner

        properties = create_api_key_openapi_record_schema.fetch(:properties).dup
        properties.delete(:key) unless include_secret
        required = create_api_key_openapi_record_schema.fetch(:required).dup
        required.delete("key") unless include_secret
        BetterAuth::OpenAPI.object_schema(properties, required: required)
      end

      def create_api_key_openapi_record_schema
        BetterAuth::OpenAPI.object_schema(
          {
            id: {type: "string", description: "Unique identifier of the API key"},
            createdAt: {type: "string", format: "date-time", description: "Creation timestamp"},
            updatedAt: {type: "string", format: "date-time", description: "Last update timestamp"},
            name: {type: "string", nullable: true, description: "Name of the API key"},
            prefix: {type: "string", nullable: true, description: "Prefix of the API key"},
            start: {type: "string", nullable: true, description: "Starting characters of the key (if configured)"},
            key: {type: "string", description: "The full API key (only returned on creation)"},
            enabled: {type: "boolean", description: "Whether the key is enabled"},
            expiresAt: {type: "string", format: "date-time", nullable: true, description: "Expiration timestamp"},
            referenceId: {type: "string", description: "ID of the reference owning the key"},
            lastRefillAt: {type: "string", format: "date-time", nullable: true, description: "Last refill timestamp"},
            lastRequest: {type: "string", format: "date-time", nullable: true, description: "Last request timestamp"},
            metadata: {type: "object", nullable: true, additionalProperties: true, description: "Metadata associated with the key"},
            rateLimitMax: {type: "number", nullable: true, description: "Maximum requests in time window"},
            rateLimitTimeWindow: {type: "number", nullable: true, description: "Rate limit time window in milliseconds"},
            remaining: {type: "number", nullable: true, description: "Remaining requests"},
            refillAmount: {type: "number", nullable: true, description: "Amount to refill"},
            refillInterval: {type: "number", nullable: true, description: "Refill interval in milliseconds"},
            rateLimitEnabled: {type: "boolean", description: "Whether rate limiting is enabled"},
            requestCount: {type: "number", description: "Current request count in window"},
            permissions: api_key_permissions_schema.merge(nullable: true, description: "Permissions associated with the key")
          },
          required: %w[id createdAt updatedAt key enabled referenceId rateLimitEnabled requestCount]
        )
      end

      def legacy_api_key_openapi_record_schema
        BetterAuth::OpenAPI.object_schema(
          {
            id: {type: "string", description: "ID"},
            name: {type: "string", nullable: true, description: "The name of the key"},
            start: {
              type: "string",
              nullable: true,
              description: "Shows the first few characters of the API key, including the prefix. This allows you to show those few characters in the UI to make it easier for users to identify the API key."
            },
            prefix: {type: "string", nullable: true, description: "The API Key prefix. Stored as plain text."},
            userId: {type: "string", description: "The owner of the user id"},
            refillInterval: {
              type: "number",
              nullable: true,
              description: "The interval in milliseconds between refills of the `remaining` count. Example: 3600000 // refill every hour (3600000ms = 1h)"
            },
            refillAmount: {type: "number", nullable: true, description: "The amount to refill"},
            lastRefillAt: {type: "string", format: "date-time", nullable: true, description: "The last refill date"},
            enabled: {type: "boolean", description: "Sets if key is enabled or disabled", default: true},
            rateLimitEnabled: {type: "boolean", description: "Whether the key has rate limiting enabled"},
            rateLimitTimeWindow: {type: "number", nullable: true, description: "The duration in milliseconds"},
            rateLimitMax: {type: "number", nullable: true, description: "Maximum amount of requests allowed within a window"},
            requestCount: {type: "number", description: "The number of requests made within the rate limit time window"},
            remaining: {
              type: "number",
              nullable: true,
              description: "Remaining requests (every time api key is used this should updated and should be updated on refill as well)"
            },
            lastRequest: {type: "string", format: "date-time", nullable: true, description: "When last request occurred"},
            expiresAt: {type: "string", format: "date-time", nullable: true, description: "Expiry date of a key"},
            createdAt: {type: "string", format: "date-time", description: "created at"},
            updatedAt: {type: "string", format: "date-time", description: "updated at"},
            metadata: {type: "object", nullable: true, additionalProperties: true, description: "Extra metadata about the apiKey"},
            permissions: {type: "string", nullable: true, description: "Permissions for the api key (stored as JSON string)"}
          },
          required: %w[id userId enabled rateLimitEnabled requestCount createdAt updatedAt]
        )
      end

      def api_key_public_record_schema
        properties = create_api_key_openapi_record_schema.fetch(:properties).dup
        properties.delete(:key)
        properties[:configId] = {type: "string", description: "The configuration ID this key belongs to"}
        BetterAuth::OpenAPI.object_schema(
          properties,
          required: %w[id configId createdAt updatedAt enabled referenceId rateLimitEnabled requestCount]
        )
      end
    end
  end
end
