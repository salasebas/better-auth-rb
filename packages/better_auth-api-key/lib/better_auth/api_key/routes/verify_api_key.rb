# frozen_string_literal: true

module BetterAuth
  module APIKey
    module Routes
      module VerifyAPIKey
        UPSTREAM_SOURCE = "reference/upstream-src/1.7.1/repository/packages/api-key/src/routes/verify-api-key.ts"

        module_function

        def body_schema(value)
          return false unless value.is_a?(Hash)

          body = BetterAuth::Plugins.normalize_hash(value)
          return false unless body[:key].is_a?(String)
          return false if body.key?(:config_id) && !body[:config_id].is_a?(String)
          if body.key?(:permissions)
            permissions = body[:permissions]
            return false unless permissions.is_a?(Hash)
            return false unless permissions.values.all? { |actions| actions.is_a?(Array) && actions.all? { |action| action.is_a?(String) } }
          end

          value
        end

        def endpoint(config)
          BetterAuth::Endpoint.new(
            path: "/api-key/verify",
            method: "POST",
            body_schema: method(:body_schema),
            metadata: Routes.openapi_for(:verify_api_key)
          ) do |ctx|
            body = BetterAuth::Plugins.normalize_hash(ctx.body)
            resolved_config = BetterAuth::Plugins.api_key_resolve_config(ctx.context, config, body[:config_id])
            key = body[:key]
            validator = resolved_config[:custom_api_key_validator]
            if body[:config_id] && validator.respond_to?(:call) && !validator.call({ctx: ctx, key: key})
              raise BetterAuth::APIError.new(
                "UNAUTHORIZED",
                message: BetterAuth::Plugins::API_KEY_ERROR_CODES["INVALID_API_KEY"],
                code: "KEY_NOT_FOUND"
              )
            else
              record = BetterAuth::Plugins.api_key_validate!(
                ctx,
                key,
                resolved_config,
                permissions: body[:permissions],
                configurations: config.fetch(:configurations, [config]),
                expected_config_id: body[:config_id],
                run_custom_validator: body[:config_id].nil?
              )
              record_config = BetterAuth::Plugins.api_key_resolve_config(ctx.context, config, BetterAuth::Plugins.api_key_record_config_id(record))
              BetterAuth::Plugins.api_key_schedule_cleanup(ctx, record_config) if record_config[:defer_updates]
              record = BetterAuth::Plugins.api_key_migrate_legacy_metadata(ctx, record, record_config)
              ctx.json({valid: true, error: nil, key: BetterAuth::Plugins.api_key_public(record, include_key_field: false)})
            end
          rescue BetterAuth::APIError => error
            ctx.context.logger.error("Failed to validate API key: #{error.message}") if ctx.context.logger.respond_to?(:error)
            payload = BetterAuth::Plugins.api_key_error_payload(error)
            payload[:code] = error.code if error.code == "KEY_NOT_FOUND"
            ctx.json(
              {valid: false, error: payload, key: nil},
              status: error.status_code,
              headers: error.headers
            )
          rescue => error
            ctx.context.logger.error("Failed to validate API key: #{error.message}") if ctx.context.logger.respond_to?(:error)
            ctx.json({valid: false, error: {message: BetterAuth::Plugins::API_KEY_ERROR_CODES["INVALID_API_KEY"], code: "INVALID_API_KEY"}, key: nil})
          end
        end
      end
    end
  end
end
